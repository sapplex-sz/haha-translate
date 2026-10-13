import Combine
import CryptoKit
import Darwin
import Foundation

enum ModelStoreError: LocalizedError {
    case operationInProgress
    case invalidFile
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch
    case insufficientSpace(required: Int64)
    case httpStatus(Int)
    case missingDownload
    case insecureRedirect

    var errorDescription: String? {
        switch self {
        case .operationInProgress: return L("另一个模型操作正在进行，请先等待或取消。")
        case .invalidFile: return L("请选择完整的官方 GGUF 模型文件。")
        case let .sizeMismatch(expected, actual):
            return L("模型大小不符（需要 %lld 字节，实际 %lld 字节），未安装该文件。", expected, actual)
        case .checksumMismatch: return L("模型 SHA-256 校验失败，文件可能损坏或不是此版本，请重新下载。")
        case let .insufficientSpace(required):
            return L("磁盘空间不足，请至少腾出 %@ 后重试。", ByteCountFormatter.string(fromByteCount: required, countStyle: .file))
        case let .httpStatus(code): return L("模型下载服务器返回 HTTP %d，请稍后重试或导入官方模型。", code)
        case .missingDownload: return L("下载未得到完整文件，请重新尝试。")
        case .insecureRedirect: return L("模型下载被重定向到非 HTTPS 地址，已停止下载。")
        }
    }
}

/// A receipt is written only after the pinned size and SHA-256 have both been verified.
/// The size and modification date invalidate it if the installed file changes later.
struct ModelInstallationReceipt: Codable {
    let model: String
    let sha256: String
    let byteCount: Int64
    let modificationDate: Date
}

enum ModelFileValidator {
    static func validate(_ url: URL, expectedSize: Int64, sha256: String,
                         isCancelled: () -> Bool = { false }) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ModelStoreError.invalidFile
        }
        let actual = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard actual == expectedSize else {
            throw ModelStoreError.sizeMismatch(expected: expectedSize, actual: actual)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            if isCancelled() { throw CancellationError() }
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { break }
            hash.update(data: data)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw ModelStoreError.checksumMismatch
        }
    }
}

private final class ModelCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

@MainActor
final class ModelStore: ObservableObject {
    @Published var selectedModel: TranslationModel {
        didSet { defaults.set(selectedModel.rawValue, forKey: Self.selectionKey) }
    }
    @Published var selectedDownloadSource: ModelDownloadSource {
        didSet { defaults.set(selectedDownloadSource.rawValue, forKey: Self.downloadSourceKey) }
    }
    @Published var downloadSourceChoice: ModelDownloadChoice {
        didSet {
            defaults.set(downloadSourceChoice.rawValue, forKey: Self.downloadChoiceKey)
            if let source = downloadSourceChoice.explicitSource { selectedDownloadSource = source }
        }
    }
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var downloadingModel: TranslationModel?
    private enum Status {
        case preparing, ready(TranslationModel), downloading(TranslationModel), resuming, verifying
        case cancelled, retrying, removed(TranslationModel), importing, imported(TranslationModel)
    }
    @Published private var status: Status?
    var statusMessage: String? {
        switch status {
        case .preparing: return L("正在准备…")
        case .ready(let model): return L("%@已就绪。", model.displayName)
        case .downloading(let model): return L("正在下载%@…", model.displayName)
        case .resuming: return L("正在恢复模型下载…")
        case .retrying: return L("连接暂时中断，正在重试…")
        case .verifying: return L("下载完成，正在校验模型…")
        case .cancelled: return L("下载已取消；如服务器支持，将在下次下载时继续。")
        case .removed(let model): return L("已移除%@。", model.displayName)
        case .importing: return L("正在导入并校验模型…")
        case .imported(let model): return L("%@已导入。", model.displayName)
        case nil: return nil
        }
    }
    @Published private(set) var errorMessage: String?
    @Published private(set) var errorDetails: String?
    @Published private(set) var failedDownloadModel: TranslationModel?
    @Published private(set) var failedDownloadSource: ModelDownloadSource?
    @Published private(set) var installedModels: Set<TranslationModel> = []

    let modelsDirectory: URL
    private let defaults: UserDefaults
    private let sessionConfiguration: URLSessionConfiguration
    private let transferFactory: ModelDownloadTransportFactory
    private let retryDelay: ModelDownloadRetryDelay
    private let sourceProbe: ModelSourceProbeFunction
    private var selectionTask: Task<[ModelDownloadSource], Error>?
    private var transfer: ModelDownloadRunner?
    private var cancellation: ModelCancellation?
    private var operationID: UUID?
    private var localizationSubscription: AnyCancellable?
    static let selectionKey = "HaHaTranslate.selectedModel"
    static let downloadSourceKey = "HaHaTranslate.modelDownloadSource"
    static let downloadChoiceKey = "HaHaTranslate.modelDownloadChoice"

    init(modelsDirectory: URL? = nil, defaults: UserDefaults = .standard,
         sessionConfiguration: URLSessionConfiguration = .ephemeral,
         transferFactory: ModelDownloadTransportFactory? = nil,
         sourceProbe: @escaping ModelSourceProbeFunction = { try await ModelSourceProbe.measure($0, $1, $2) },
         retryDelay: @escaping ModelDownloadRetryDelay = { try await Task.sleep(nanoseconds: 600_000_000) }) {
        self.defaults = defaults
        self.sessionConfiguration = sessionConfiguration
        self.transferFactory = transferFactory ?? { destination, configuration, progress in
            ModelDownloadTransfer(destination: destination, configuration: configuration, progress: progress)
        }
        self.retryDelay = retryDelay
        self.sourceProbe = sourceProbe
        self.modelsDirectory = modelsDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HaHaTranslate/Models", isDirectory: true)
        selectedModel = defaults.string(forKey: Self.selectionKey)
            .flatMap(TranslationModel.init(rawValue:)) ?? .light
        selectedDownloadSource = defaults.string(forKey: Self.downloadSourceKey)
            .flatMap(ModelDownloadSource.init(rawValue:)) ?? .huggingFace
        downloadSourceChoice = defaults.string(forKey: Self.downloadChoiceKey)
            .flatMap(ModelDownloadChoice.init(rawValue:)) ?? .automatic
        if let explicit = downloadSourceChoice.explicitSource { selectedDownloadSource = explicit }
        refreshInstallations()
        localizationSubscription = AppLocalization.shared.$language.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                // Errors are transient presentation strings, not saved model state.
                self?.errorMessage = nil
                self?.errorDetails = nil
                self?.failedDownloadModel = nil
                self?.failedDownloadSource = nil
            }
        }
    }

    func isInstalled(_ model: TranslationModel) -> Bool {
        receiptMatchesFile(model)
    }

    func modelURL(for model: TranslationModel) -> URL? {
        isInstalled(model) ? destination(for: model) : nil
    }

    func download(_ model: TranslationModel, from source: ModelDownloadSource? = nil) async {
        guard operationID == nil else {
            errorMessage = ModelStoreError.operationInProgress.localizedDescription
            errorDetails = nil
            return
        }
        if isInstalled(model) {
            status = .ready(model)
            errorMessage = nil; errorDetails = nil; failedDownloadModel = nil; failedDownloadSource = nil
            return
        }
        let id = UUID()
        let token = ModelCancellation()
        begin(model, id: id, token: token)
        defer { finish(id: id) }
        let explicit = source ?? downloadSourceChoice.explicitSource
        var activeSource = explicit
        var sourceURL = explicit.map { model.downloadURL(for: $0) }
        var resumeFile: URL?
        let staging = stagingURL(for: model)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try prepareDirectory(requiredSpace: model.byteCount + 128 * 1_024 * 1_024)
            let sources: [ModelDownloadSource]
            if let explicit { sources = [explicit] }
            else {
                status = .preparing
                let configuration = sessionConfiguration
                let probe = sourceProbe
                let task = Task { try await ModelSourceSelector.rankedSources(for: model, configuration: configuration, probe: probe) }
                selectionTask = task
                sources = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                selectionTask = nil
            }
            if token.isCancelled { throw CancellationError() }
            try Task.checkCancellation()
            for (index, candidate) in sources.enumerated() {
                if token.isCancelled { throw CancellationError() }
                try Task.checkCancellation()
                activeSource = candidate
                selectedDownloadSource = candidate
                let url = model.downloadURL(for: candidate)
                sourceURL = url
                let resume = resumeURL(for: model, source: url)
                resumeFile = resume
                migrateLegacyResume(for: model, source: url, to: resume)
                let runner = ModelDownloadRunner(configuration: sessionConfiguration,
                factory: transferFactory, retryDelay: retryDelay, progress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard self?.operationID == id else { return }
                        self?.downloadProgress = progress
                    }
                }, phaseChanged: { [weak self] phase in
                    guard let self, operationID == id else { return }
                    switch phase {
                    case .downloading: status = .downloading(model); downloadProgress = 0
                    case .resuming: status = .resuming
                    case .retrying: status = .retrying
                    }
                })
                transfer = runner
                let file: URL
                do {
                    file = try await runner.download(from: url, destination: staging,
                                                 resumeFile: resume, expectedSize: model.byteCount)
                } catch {
                    if !token.isCancelled && !Task.isCancelled && index + 1 < sources.count && Self.canTryNextSource(error) {
                        try? FileManager.default.removeItem(at: staging)
                        transfer = nil
                        continue
                    }
                    throw error
                }
                defer { try? FileManager.default.removeItem(at: file) }
                if token.isCancelled { throw CancellationError() }
                try Task.checkCancellation()
                status = .verifying; downloadProgress = 1
                try await verifyAndInstall(file, as: model, token: token)
                try? FileManager.default.removeItem(at: resume)
                status = .ready(model)
                break
            }
        } catch {
            if token.isCancelled || Task.isCancelled || ModelDownloadErrorPolicy.isCancellation(error) {
                status = .cancelled
            } else {
                // Invalid downloaded contents must not leave a stale resume for the next click.
                switch ModelDownloadErrorPolicy.underlying(error) {
                case ModelStoreError.checksumMismatch, ModelStoreError.sizeMismatch:
                    if let resumeFile { try? FileManager.default.removeItem(at: resumeFile) }
                default: break
                }
                status = nil
                errorMessage = friendlyMessage(error)
                errorDetails = (error as? ModelSourceSelectionError)?.diagnostics.joined(separator: "\n")
                    ?? ModelDownloadDiagnostics.details(for: error, fallbackURL: sourceURL)
                failedDownloadModel = model
                failedDownloadSource = activeSource
            }
        }
    }

    func cancelDownload() {
        cancellation?.cancel()
        selectionTask?.cancel()
        transfer?.cancel()
    }

    private static func canTryNextSource(_ error: Error) -> Bool {
        if ModelDownloadErrorPolicy.isCancellation(error) { return false }
        // Switching to another independently verified HTTPS source does not bypass trust.
        let underlying = ModelDownloadErrorPolicy.underlying(error)
        if case ModelStoreError.httpStatus = underlying { return true }
        let ns = underlying as NSError
        return ns.domain == NSURLErrorDomain
    }

    func delete(_ model: TranslationModel) throws {
        guard downloadingModel != model else { throw ModelStoreError.operationInProgress }
        // Only this manifest entry and its own verification/resume metadata are removed.
        let resumes = model.downloadURLs.map { resumeURL(for: model, source: $0) }
        for file in [destination(for: model), receiptURL(for: model),
                     ModelDownloadResumeFiles.legacyURL(directory: modelsDirectory, model: model)] + resumes {
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
        refreshInstallations()
        status = .removed(model)
    }

    func importModel(from source: URL, as model: TranslationModel) async throws {
        guard operationID == nil else { throw ModelStoreError.operationInProgress }
        let id = UUID()
        let token = ModelCancellation()
        begin(model, id: id, token: token)
        defer { finish(id: id) }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let staging = stagingURL(for: model)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try prepareDirectory(requiredSpace: model.byteCount + 128 * 1_024 * 1_024)
            status = .importing
            try await Task.detached(priority: .utility) {
                // Validate before copying to reject unrelated or incomplete files early.
                try ModelFileValidator.validate(source, expectedSize: model.byteCount,
                                                sha256: model.sha256, isCancelled: { token.isCancelled })
                if token.isCancelled { throw CancellationError() }
                try FileManager.default.copyItem(at: source, to: staging)
            }.value
            // Verify the copied bytes too: the source may have changed while being copied.
            try await verifyAndInstall(staging, as: model, token: token)
            status = .imported(model)
        } catch {
            status = nil
            errorMessage = error is CancellationError ? L("导入已取消。") : friendlyMessage(error)
            errorDetails = error is CancellationError ? nil : ModelDownloadDiagnostics.details(for: error)
            throw error
        }
    }

    private func begin(_ model: TranslationModel, id: UUID, token: ModelCancellation) {
        operationID = id
        cancellation = token
        downloadingModel = model
        downloadProgress = 0
        errorMessage = nil
        errorDetails = nil
        failedDownloadModel = nil
        failedDownloadSource = nil
    }

    private func finish(id: UUID) {
        guard operationID == id else { return }
        transfer = nil
        selectionTask = nil
        cancellation = nil
        operationID = nil
        downloadingModel = nil
        downloadProgress = nil
        refreshInstallations()
    }

    private func prepareDirectory(requiredSpace: Int64) throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        var excluded = modelsDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        let capacity = try modelsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = capacity.volumeAvailableCapacityForImportantUsage, free < requiredSpace {
            throw ModelStoreError.insufficientSpace(required: requiredSpace)
        }
    }

    private func verifyAndInstall(_ staging: URL, as model: TranslationModel,
                                  token: ModelCancellation) async throws {
        try await Task.detached(priority: .utility) {
            try ModelFileValidator.validate(staging, expectedSize: model.byteCount,
                                            sha256: model.sha256, isCancelled: { token.isCancelled })
        }.value
        if token.isCancelled { throw CancellationError() }
        try Task.checkCancellation()
        let target = destination(for: model)
        // Both paths are in the same directory/volume; POSIX rename atomically replaces only target.
        let result = staging.path.withCString { src in
            target.path.withCString { dst in Darwin.rename(src, dst) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        let receipt = ModelInstallationReceipt(model: model.rawValue, sha256: model.sha256,
            byteCount: model.byteCount, modificationDate: attributes[.modificationDate] as? Date ?? .distantPast)
        try JSONEncoder().encode(receipt).write(to: receiptURL(for: model), options: .atomic)
        refreshInstallations()
    }

    private func receiptMatchesFile(_ model: TranslationModel) -> Bool {
        guard let data = try? Data(contentsOf: receiptURL(for: model)),
              let receipt = try? JSONDecoder().decode(ModelInstallationReceipt.self, from: data),
              receipt.model == model.rawValue, receipt.sha256 == model.sha256,
              receipt.byteCount == model.byteCount,
              let attrs = try? FileManager.default.attributesOfItem(atPath: destination(for: model).path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? NSNumber)?.int64Value == model.byteCount,
              attrs[.modificationDate] as? Date == receipt.modificationDate else { return false }
        return true
    }

    private func refreshInstallations() {
        installedModels = Set(TranslationModel.allCases.filter { receiptMatchesFile($0) })
    }
    private func destination(for model: TranslationModel) -> URL {
        modelsDirectory.appendingPathComponent(model.filename)
    }
    private func receiptURL(for model: TranslationModel) -> URL {
        modelsDirectory.appendingPathComponent(".\(model.rawValue)-\(model.sha256).verified.json")
    }
    private func resumeURL(for model: TranslationModel, source: URL) -> URL {
        ModelDownloadResumeFiles.url(directory: modelsDirectory, model: model, source: source)
    }
    private func migrateLegacyResume(for model: TranslationModel, source: URL, to target: URL) {
        // Releases before source isolation only downloaded this exact official URL.
        let official = URL(string: "https://huggingface.co/\(model.repository)/resolve/\(model.revision)/\(model.filename)")
        guard source == official, !FileManager.default.fileExists(atPath: target.path) else { return }
        let legacy = ModelDownloadResumeFiles.legacyURL(directory: modelsDirectory, model: model)
        if FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: target)
        }
    }

    private func stagingURL(for model: TranslationModel) -> URL {
        modelsDirectory.appendingPathComponent(".\(model.rawValue)-\(UUID().uuidString).partial")
    }
    private func friendlyMessage(_ error: Error) -> String {
        if let selection = error as? ModelSourceSelectionError { return selection.localizedDescription }
        let underlying = ModelDownloadErrorPolicy.underlying(error)
        if let known = underlying as? ModelStoreError { return known.localizedDescription }
        let nsError = underlying as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError {
            return L("磁盘空间不足，下载未安装。请腾出空间后重试。")
        }
        if ModelDownloadErrorPolicy.isCertificateFailure(error) {
            return L("下载服务器的证书未通过系统验证。请检查系统时间和网络设置，或联系支持；应用不会绕过证书验证。")
        }
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorSecureConnectionFailed:
                return L("无法与下载服务器建立安全连接。请稍后重试，或检查当前网络、代理与系统时间；也可以导入官方模型。")
            case NSURLErrorTimedOut:
                return L("下载连接超时。请稍后重试，或切换网络后继续下载。")
            case NSURLErrorNetworkConnectionLost:
                return L("下载连接意外中断。已保留可用的下载进度，请重试。")
            case NSURLErrorNotConnectedToInternet:
                return L("当前无法连接网络。请连接网络后重试；已保留可用的下载进度。")
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorCannotConnectToHost:
                return L("无法连接下载服务器。请检查网络或代理设置后重试。")
            default: break
            }
        }
        return L("模型操作未能完成。请重试，或复制错误详情联系支持。")
    }

}

/// URLSession owns its temporary download file until didFinishDownloadingTo returns.
/// The transport never writes resume files; it returns fresh resume data with
/// completion after both cancellation callbacks and task completion have arrived.
private final class ModelDownloadTransfer: NSObject, ModelDownloadTransport, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let configuration: URLSessionConfiguration
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var cancellationRequested = false
    private var cancellationSent = false
    private var pendingResumeCallback = false
    private var completionReceived = false
    private var completionError: Error?
    private var freshResumeData: Data?
    private var serverHost: String?
    private var outcome = ModelDownloadOutcome()
    private var expectedSize: Int64 = 0

    init(destination: URL, configuration: URLSessionConfiguration,
         progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.progress = progress
    }

    func download(from url: URL, resumeData: Data?, expectedSize: Int64) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                self.expectedSize = expectedSize
                self.serverHost = url.host
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 48 * 60 * 60
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                self.session = session
                let task: URLSessionDownloadTask
                if let resumeData {
                    task = session.downloadTask(withResumeData: resumeData)
                } else {
                    var request = URLRequest(url: url)
                    request.setValue("HaHaTranslate/1.0", forHTTPHeaderField: "User-Agent")
                    task = session.downloadTask(with: request)
                }
                self.task = task
                let cancelled = cancellationRequested
                lock.unlock()
                task.resume()
                if cancelled { cancel() }
            }
        } onCancel: { self.cancel() }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        guard let task, !cancellationSent else { lock.unlock(); return }
        cancellationSent = true
        pendingResumeCallback = true
        lock.unlock()
        task.cancel(byProducingResumeData: { [self] data in
            lock.lock()
            if let data, !data.isEmpty { freshResumeData = data }
            pendingResumeCallback = false
            lock.unlock()
            finishIfReady()
        })
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progress(min(1, max(0, Double(totalBytesWritten) / Double(max(1, expectedSize)))))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        lock.lock()
        if case .failure = outcome.result { lock.unlock(); return }
        if cancellationRequested { lock.unlock(); return }
        serverHost = downloadTask.response?.url?.host ?? serverHost
        lock.unlock()
        guard let response = downloadTask.response as? HTTPURLResponse else {
            record(.failure(ModelStoreError.missingDownload)); return
        }
        guard response.statusCode == 200 || response.statusCode == 206 else {
            record(.failure(ModelStoreError.httpStatus(response.statusCode))); return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            record(.success(destination))
        } catch { record(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock(); serverHost = request.url?.host ?? serverHost; lock.unlock()
        guard request.url?.scheme?.lowercased() == "https" else {
            record(.failure(ModelStoreError.insecureRedirect))
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if let data = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, !data.isEmpty {
            freshResumeData = data
        }
        if let error { serverHost = ModelDownloadDiagnostics.failingHost(in: error) ?? task.currentRequest?.url?.host ?? serverHost }
        completionError = error
        completionReceived = true
        lock.unlock()
        finishIfReady()
    }

    private func record(_ result: Result<URL, Error>) {
        lock.lock(); outcome.record(result); lock.unlock()
    }

    private func finishIfReady() {
        lock.lock()
        guard completionReceived, !pendingResumeCallback, let continuation else { lock.unlock(); return }
        let result = outcome.completed(error: completionError, userCancelled: cancellationRequested)
        let resumeData = freshResumeData
        let host = serverHost
        let session = self.session
        self.continuation = nil
        self.task = nil
        self.session = nil
        lock.unlock()
        switch result {
        case .success(let url): continuation.resume(returning: url)
        case .failure(let error):
            continuation.resume(throwing: ModelDownloadFailure(underlying: error, resumeData: resumeData, serverHost: host))
        }
        session?.finishTasksAndInvalidate()
    }
}
