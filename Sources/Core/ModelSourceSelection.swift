import Foundation

struct ModelSourceMeasurement: Sendable {
    let source: ModelDownloadSource
    let sampledBytes: Int
    let elapsed: TimeInterval
    var bytesPerSecond: Double { Double(sampledBytes) / max(elapsed, 0.001) }
}

typealias ModelSourceProbeFunction = @Sendable (TranslationModel, ModelDownloadSource, URLSessionConfiguration) async throws -> ModelSourceMeasurement

struct ModelSourceSelectionError: LocalizedError {
    let diagnostics: [String]
    var errorDescription: String? {
        L("暂时无法连接模型下载线路。请检查网络、代理与系统时间后重试，或手动指定来源。")
    }
}

enum ModelSourceSelector {
    static func rankedSources(for model: TranslationModel, configuration: URLSessionConfiguration,
                              probe: @escaping ModelSourceProbeFunction = { try await ModelSourceProbe.measure($0, $1, $2) }) async throws -> [ModelDownloadSource] {
        struct Outcome: Sendable {
            let measurement: ModelSourceMeasurement?
            let diagnostic: String?
        }
        return try await withThrowingTaskGroup(of: Outcome.self) { group in
            for source in ModelDownloadSource.allCases {
                group.addTask {
                    do {
                        let value = try await probe(model, source, configuration)
                        try Task.checkCancellation()
                        guard value.sampledBytes > 0, value.elapsed.isFinite, value.elapsed > 0 else {
                            throw URLError(.badServerResponse)
                        }
                        return Outcome(measurement: value, diagnostic: nil)
                    } catch {
                        if Task.isCancelled || ModelDownloadErrorPolicy.isCancellation(error) { throw CancellationError() }
                        return Outcome(measurement: nil, diagnostic: ModelDownloadDiagnostics.details(
                            for: error, fallbackURL: model.downloadURL(for: source)))
                    }
                }
            }
            var measurements: [ModelSourceMeasurement] = []
            var diagnostics: [String] = []
            for try await outcome in group {
                if let measurement = outcome.measurement { measurements.append(measurement) }
                if let diagnostic = outcome.diagnostic { diagnostics.append(diagnostic) }
            }
            try Task.checkCancellation()
            guard !measurements.isEmpty else { throw ModelSourceSelectionError(diagnostics: diagnostics.sorted()) }
            return measurements.sorted {
                if $0.bytesPerSecond == $1.bytesPerSecond {
                    return $0.source.rawValue < $1.source.rawValue
                }
                return $0.bytesPerSecond > $1.bytesPerSecond
            }.map(\.source)
        }
    }
}

/// A bounded streaming GET includes DNS, TLS and response latency in its score.
/// No payload is retained, and even a server ignoring Range is cancelled at the cap.
final class ModelSourceProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let sampleLimit = 1_048_576
    static let deadline: TimeInterval = 5
    private let source: ModelDownloadSource
    private let url: URL
    private let expectedSize: Int64
    private let configuration: URLSessionConfiguration
    private let limit: Int
    private let timeout: TimeInterval
    private let minimumBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ModelSourceMeasurement, Error>?
    private var result: Result<ModelSourceMeasurement, Error>?
    private var session: URLSession?
    private var timer: DispatchWorkItem?
    private var started: ContinuousClock.Instant?
    private var bytes = 0
    private var acceptedResponse = false

    init(source: ModelDownloadSource, url: URL, expectedSize: Int64,
         configuration: URLSessionConfiguration, limit: Int = sampleLimit,
         timeout: TimeInterval = deadline, minimumBytes: Int = 16_384) {
        self.source = source; self.url = url; self.expectedSize = expectedSize
        self.configuration = configuration; self.limit = limit; self.timeout = timeout
        self.minimumBytes = min(minimumBytes, limit)
    }

    static func measure(_ model: TranslationModel, _ source: ModelDownloadSource,
                        _ configuration: URLSessionConfiguration) async throws -> ModelSourceMeasurement {
        try await ModelSourceProbe(source: source, url: model.downloadURL(for: source),
            expectedSize: model.byteCount, configuration: configuration).run()
    }

    func run() async throws -> ModelSourceMeasurement {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result { lock.unlock(); continuation.resume(with: result); return }
                self.continuation = continuation
                guard url.scheme?.lowercased() == "https" else {
                    lock.unlock(); finish(.failure(ModelStoreError.insecureRedirect)); return
                }
                let config = configuration.copy() as! URLSessionConfiguration
                config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
                config.httpCookieStorage = nil; config.httpShouldSetCookies = false
                config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
                request.setValue("bytes=0-\(limit - 1)", forHTTPHeaderField: "Range")
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let task = session.dataTask(with: request)
                let timer = DispatchWorkItem { [weak self] in self?.finishSample(deadlineReached: true) }
                self.timer = timer; started = ContinuousClock.now
                lock.unlock()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
                task.resume()
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }

    private func finishSample(deadlineReached: Bool) {
        lock.lock()
        let measured = bytes
        let accepted = acceptedResponse
        let start = started
        lock.unlock()
        guard accepted, measured >= minimumBytes, let start else {
            finish(.failure(URLError(deadlineReached ? .timedOut : .badServerResponse))); return
        }
        let duration = start.duration(to: ContinuousClock.now).components
        let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        finish(.success(.init(source: source, sampledBytes: measured, elapsed: max(elapsed, 0.001))))
    }

    private func finish(_ result: Result<ModelSourceMeasurement, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation; self.continuation = nil
        let session = self.session; self.session = nil
        let timer = self.timer; self.timer = nil
        lock.unlock()
        timer?.cancel()
        continuation?.resume(with: result)
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme?.lowercased() == "https" else {
            finish(.failure(ModelStoreError.insecureRedirect)); completionHandler(nil); return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard response.url?.scheme?.lowercased() == "https", let http = response as? HTTPURLResponse else {
            finish(.failure(URLError(.badServerResponse))); completionHandler(.cancel); return
        }
        let valid: Bool
        if http.statusCode == 206 {
            // Exact total/offset prevent an HTML error page or unrelated range from winning.
            let range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
            let parts = range.split(separator: " ")
            let sizes = parts.last?.split(separator: "/") ?? []
            let offsets = sizes.first?.split(separator: "-") ?? []
            valid = parts.count == 2 && parts.first == "bytes" && sizes.count == 2 && offsets.count == 2
                && Int64(sizes[1]) == expectedSize && offsets[0] == "0"
                && (Int(offsets[1]).map { $0 >= 0 && $0 < limit } ?? false)
        } else if http.statusCode == 200 {
            valid = response.expectedContentLength == expectedSize
        } else {
            finish(.failure(ModelStoreError.httpStatus(http.statusCode))); completionHandler(.cancel); return
        }
        guard valid else { finish(.failure(URLError(.badServerResponse))); completionHandler(.cancel); return }
        lock.lock(); acceptedResponse = true; let active = result == nil; lock.unlock()
        completionHandler(active ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        bytes = min(limit, bytes + data.count)
        let full = bytes == limit
        lock.unlock()
        if full { finishSample(deadlineReached: false) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let ns = error as NSError
            // URLSession's own timeout can arrive before the hard deadline callback.
            // A validated partial sample still measures this slow route fairly.
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut {
                finishSample(deadlineReached: true)
            } else { finish(.failure(error)) }
        }
        else { finishSample(deadlineReached: false) }
    }
}
