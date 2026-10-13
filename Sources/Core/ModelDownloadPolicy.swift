import CryptoKit
import Foundation
import Security

/// Resume bytes travel with the failed attempt, so an old cancellation callback
/// cannot overwrite a newer attempt's resume file after it has already finished.
struct ModelDownloadFailure: Error {
    let underlying: Error
    let resumeData: Data?
    let serverHost: String?
}

protocol ModelDownloadTransport: AnyObject, Sendable {
    func download(from url: URL, resumeData: Data?, expectedSize: Int64) async throws -> URL
    func cancel()
}

typealias ModelDownloadTransportFactory = @MainActor (
    URL, URLSessionConfiguration, @escaping @Sendable (Double) -> Void
) -> any ModelDownloadTransport
typealias ModelDownloadRetryDelay = @Sendable () async throws -> Void

enum ModelDownloadErrorPolicy {
    static func underlying(_ error: Error) -> Error {
        (error as? ModelDownloadFailure)?.underlying ?? error
    }

    static func isCancellation(_ error: Error) -> Bool {
        let error = underlying(error)
        let ns = error as NSError
        return error is CancellationError || (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled)
    }

    static func isCertificateFailure(_ error: Error) -> Bool {
        var current = underlying(error) as NSError
        let certificateCodes: Set<Int> = [NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
            NSURLErrorClientCertificateRequired]
        let sslCertificateCodes = Set([errSSLXCertChainInvalid, errSSLBadCert, errSSLUnknownRootCert,
            errSSLNoRootCert, errSSLCertExpired, errSSLCertNotYetValid, errSSLPeerBadCert,
            errSSLPeerUnsupportedCert, errSSLPeerCertRevoked, errSSLPeerCertExpired,
            errSSLPeerCertUnknown, errSSLPeerUnknownCA, errSSLClientCertRequested,
            errSSLBadCertificateStatusResponse, errSSLCertificateRequired,
            errSSLATSLeafCertificateHashAlgorithmViolation, errSSLATSCertificateHashAlgorithmViolation,
            errSSLATSCertificateTrustViolation].map(Int.init))
        // Bound traversal even for a malformed underlying-error chain.
        for _ in 0..<8 {
            if current.domain == NSURLErrorDomain && certificateCodes.contains(current.code) { return true }
            if [NSOSStatusErrorDomain, "NSStreamSocketSSLErrorDomain"].contains(current.domain),
               sslCertificateCodes.contains(current.code) { return true }
            guard let next = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = next
        }
        return false
    }

    static func isTransient(_ error: Error) -> Bool {
        guard !isCertificateFailure(error) else { return false }
        let ns = underlying(error) as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorSecureConnectionFailed, NSURLErrorTimedOut,
                NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost].contains(ns.code)
    }

    static func invalidatesResume(_ error: Error) -> Bool {
        let error = underlying(error)
        if case ModelStoreError.httpStatus(let status) = error { return status == 403 || status == 416 }
        let ns = error as NSError
        // These indicate an unusable resumed request or missing local temporary file.
        // There is no public URLError.cannotResume code in the macOS SDK. Do not
        // treat generic unknown/network errors as proof that a resume is invalid.
        return ns.domain == NSURLErrorDomain && [NSURLErrorBadURL, NSURLErrorUnsupportedURL,
            NSURLErrorFileDoesNotExist, NSURLErrorCannotOpenFile].contains(ns.code)
    }

    static func resumeData(in error: Error) -> Data? {
        let data = (error as? ModelDownloadFailure)?.resumeData ??
            (underlying(error) as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        return data.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Only domain, numeric code and hostname are suitable for the copyable report.
/// Never include NSError.description, userInfo, URL paths or signed CDN queries.
enum ModelDownloadDiagnostics {
    static func details(for error: Error, fallbackURL: URL? = nil) -> String {
        let original = ModelDownloadErrorPolicy.underlying(error)
        let ns = original as NSError
        let domain: String
        let code: Int
        if case ModelStoreError.httpStatus(let status) = original {
            domain = "HTTP"; code = status
        } else {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
            domain = ns.domain.count <= 128 && ns.domain.unicodeScalars.allSatisfy(allowed.contains)
                ? ns.domain : "UnknownError"
            code = ns.code
        }
        let host = failingHost(in: original) ?? safeHost((error as? ModelDownloadFailure)?.serverHost)
            ?? safeHost(fallbackURL?.host) ?? "-"
        return "domain=\(domain); code=\(code); host=\(host)"
    }

    static func failingHost(in error: Error) -> String? {
        let ns = error as NSError
        if let url = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL { return safeHost(url.host) }
        if let string = ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String,
           let url = URL(string: string) { return safeHost(url.host) }
        return nil
    }

    private static func safeHost(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= 253 else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]")
        guard value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return value.lowercased()
    }
}

/// The first explicit failure wins over later delegate results (for example,
/// a refused insecure redirect followed by the original HTTP 302 body).
struct ModelDownloadOutcome {
    private(set) var result: Result<URL, Error>?
    mutating func record(_ value: Result<URL, Error>) {
        if case .failure = result { return }
        result = value
    }
    func completed(error: Error?, userCancelled: Bool) -> Result<URL, Error> {
        if userCancelled { return .failure(CancellationError()) }
        if case .failure = result { return result! }
        if let error { return .failure(error) }
        return result ?? .failure(ModelStoreError.missingDownload)
    }
}

enum ModelDownloadResumeFiles {
    static func url(directory: URL, model: TranslationModel, source: URL) -> URL {
        let sourceHash = SHA256.hash(data: Data(source.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(".\(model.rawValue)-\(model.sha256)-\(sourceHash).resume")
    }
    static func legacyURL(directory: URL, model: TranslationModel) -> URL {
        directory.appendingPathComponent(".\(model.rawValue)-\(model.sha256).resume")
    }
}

/// One transient retry, plus at most one restart for a demonstrably invalid
/// resumed request. Every attempt stays on the user's original fixed URL.
@MainActor final class ModelDownloadRunner {
    enum Phase { case downloading, resuming, retrying }
    private let configuration: URLSessionConfiguration
    private let factory: ModelDownloadTransportFactory
    private let retryDelay: ModelDownloadRetryDelay
    private let progress: @Sendable (Double) -> Void
    private let phaseChanged: (Phase) -> Void
    private var transfer: (any ModelDownloadTransport)?
    private var delayTask: Task<Void, Error>?
    private var cancelled = false

    init(configuration: URLSessionConfiguration, factory: @escaping ModelDownloadTransportFactory,
         retryDelay: @escaping ModelDownloadRetryDelay,
         progress: @escaping @Sendable (Double) -> Void = { _ in },
         phaseChanged: @escaping (Phase) -> Void = { _ in }) {
        self.configuration = configuration
        self.factory = factory
        self.retryDelay = retryDelay
        self.progress = progress
        self.phaseChanged = phaseChanged
    }

    func cancel() {
        cancelled = true
        transfer?.cancel()
        delayTask?.cancel()
    }

    func download(from source: URL, destination: URL, resumeFile: URL, expectedSize: Int64) async throws -> URL {
        var transientRetryAvailable = true
        var cleanRetryAvailable = true
        var resumeData = Self.readResume(resumeFile)
        defer { transfer = nil; delayTask = nil }
        while true {
            try checkCancellation()
            let usedResume = resumeData != nil
            let job = factory(destination, configuration, progress)
            transfer = job
            phaseChanged(usedResume ? .resuming : .downloading)
            do {
                let file = try await job.download(from: source, resumeData: resumeData, expectedSize: expectedSize)
                try checkCancellation()
                return file
            } catch {
                try? FileManager.default.removeItem(at: destination)
                // Persist fresh progress before classifying the error, including cancellation.
                // Without fresh bytes, retain the previous resume file unchanged.
                if let fresh = ModelDownloadErrorPolicy.resumeData(in: error) {
                    try? fresh.write(to: resumeFile, options: .atomic)
                    resumeData = fresh
                }
                if cancelled || Task.isCancelled || ModelDownloadErrorPolicy.isCancellation(error) {
                    throw CancellationError()
                }
                if usedResume && ModelDownloadErrorPolicy.invalidatesResume(error) {
                    resumeData = nil
                    try? FileManager.default.removeItem(at: resumeFile)
                    if cleanRetryAvailable {
                        cleanRetryAvailable = false
                        continue
                    }
                }
                if transientRetryAvailable && ModelDownloadErrorPolicy.isTransient(error) {
                    transientRetryAvailable = false
                    phaseChanged(.retrying)
                    let delay = Task { try await retryDelay() }
                    delayTask = delay
                    try await withTaskCancellationHandler {
                        try await delay.value
                    } onCancel: { delay.cancel() }
                    try checkCancellation()
                    continue
                }
                throw error
            }
        }
    }

    private func checkCancellation() throws {
        if cancelled { throw CancellationError() }
        try Task.checkCancellation()
    }
    private static func readResume(_ url: URL) -> Data? {
        (try? Data(contentsOf: url)).flatMap { $0.isEmpty ? nil : $0 }
    }
}
