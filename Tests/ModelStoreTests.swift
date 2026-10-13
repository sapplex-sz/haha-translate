import CryptoKit
import Foundation
import XCTest
@testable import HaHaCore

final class ModelStoreTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaHaModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "HaHaModelStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testPinnedManifestUsesExactModelRevisionAndSHA256() {
        XCTAssertEqual(TranslationModel.light.byteCount, 461_860_800)
        XCTAssertEqual(TranslationModel.standard.byteCount, 1_133_080_448)
        for model in TranslationModel.allCases {
            XCTAssertEqual(model.sha256.count, 64)
            XCTAssertEqual(model.revision.count, 40)
            XCTAssertEqual(model.downloadURLs.count, 2)
            XCTAssertEqual(model.downloadURLs[0].host, "huggingface.co")
            XCTAssertEqual(model.downloadURLs[0].scheme, "https")
            XCTAssertTrue(model.downloadURLs[0].path.contains("/resolve/\(model.revision)/"))
            XCTAssertEqual(model.downloadURLs[0].lastPathComponent, model.filename)
            let alternative = model.downloadURL(for: .modelScope)
            XCTAssertEqual(alternative.scheme, "https")
            XCTAssertEqual(alternative.host, "modelscope.cn")
            XCTAssertTrue(alternative.path.hasPrefix("/api/v1/models/Tencent-Hunyuan/"))
            let query = URLComponents(url: alternative, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first(where: { $0.name == "Revision" })?.value?.count, 40)
            XCTAssertEqual(query?.first(where: { $0.name == "FilePath" })?.value, model.filename)
        }
    }

    func testValidationChecksSizeAndContentIndependently() throws {
        let file = try temporaryDirectory().appendingPathComponent("fixture.gguf")
        let data = Data("the verified bytes".utf8)
        try data.write(to: file)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertNoThrow(try ModelFileValidator.validate(file, expectedSize: Int64(data.count), sha256: digest))
        XCTAssertThrowsError(try ModelFileValidator.validate(file, expectedSize: Int64(data.count + 1), sha256: digest)) {
            guard case ModelStoreError.sizeMismatch = $0 else { return XCTFail("Expected size error, got \($0)") }
        }
        XCTAssertThrowsError(try ModelFileValidator.validate(file, expectedSize: Int64(data.count), sha256: String(repeating: "0", count: 64))) {
            guard case ModelStoreError.checksumMismatch = $0 else { return XCTFail("Expected checksum error, got \($0)") }
        }
    }

    func testValidationCanBeCancelledAndRejectsSymlinks() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("fixture.gguf")
        try Data("bytes".utf8).write(to: file)
        XCTAssertThrowsError(try ModelFileValidator.validate(file, expectedSize: 5, sha256: "", isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
        let link = directory.appendingPathComponent("link.gguf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try ModelFileValidator.validate(link, expectedSize: 5, sha256: "")) {
            guard case ModelStoreError.invalidFile = $0 else { return XCTFail("Expected regular-file check") }
        }
    }

    @MainActor
    func testLightIsDefaultAndSelectionSurvivesRelaunch() throws {
        let directory = try temporaryDirectory()
        let defaults = isolatedDefaults()
        let first = ModelStore(modelsDirectory: directory, defaults: defaults)
        XCTAssertEqual(first.selectedModel, .light)
        first.selectedModel = .standard
        let second = ModelStore(modelsDirectory: directory, defaults: defaults)
        XCTAssertEqual(second.selectedModel, .standard)
        defaults.set("removed-model", forKey: ModelStore.selectionKey)
        XCTAssertEqual(ModelStore(modelsDirectory: directory, defaults: defaults).selectedModel, .light)
    }

    @MainActor
    func testDownloadSourceDefaultsToOfficialAndPersistsExplicitChoice() throws {
        let directory = try temporaryDirectory()
        let defaults = isolatedDefaults()
        let first = ModelStore(modelsDirectory: directory, defaults: defaults)
        XCTAssertEqual(first.selectedDownloadSource, .huggingFace)
        first.selectedDownloadSource = .modelScope
        XCTAssertEqual(ModelStore(modelsDirectory: directory, defaults: defaults).selectedDownloadSource, .modelScope)
        defaults.set("removed-source", forKey: ModelStore.downloadSourceKey)
        XCTAssertEqual(ModelStore(modelsDirectory: directory, defaults: defaults).selectedDownloadSource, .huggingFace)
    }

    @MainActor
    func testAutomaticChoiceIsDefaultAndExplicitChoicePersists() throws {
        let directory = try temporaryDirectory(), defaults = isolatedDefaults()
        defaults.set("modelScope", forKey: ModelStore.downloadSourceKey)
        let store = ModelStore(modelsDirectory: directory, defaults: defaults)
        XCTAssertEqual(store.downloadSourceChoice, .automatic)
        store.downloadSourceChoice = .modelScope
        let relaunched = ModelStore(modelsDirectory: directory, defaults: defaults)
        XCTAssertEqual(relaunched.downloadSourceChoice, .modelScope)
        XCTAssertEqual(relaunched.selectedDownloadSource, .modelScope)
    }

    @MainActor
    func testAutomaticChoosesFastestAndFallsBackWithIsolatedResumeFiles() async throws {
        let directory = try temporaryDirectory()
        let old = Data("HF progress".utf8)
        let firstURL = TranslationModel.light.downloadURL(for: .huggingFace)
        let secondURL = TranslationModel.light.downloadURL(for: .modelScope)
        let firstResume = ModelDownloadResumeFiles.url(directory: directory, model: .light, source: firstURL)
        try old.write(to: firstResume)
        let plan = DownloadTestPlan([.failure(URLError(.timedOut)), .failure(URLError(.timedOut)),
                                     .failure(ModelStoreError.httpStatus(503))])
        let store = ModelStore(modelsDirectory: directory, defaults: isolatedDefaults(), transferFactory: plan.factory,
            sourceProbe: { _, source, _ in
                .init(source: source, sampledBytes: 1024, elapsed: source == .huggingFace ? 0.1 : 1)
            }, retryDelay: {})
        await store.download(.light)
        XCTAssertEqual(plan.requests.map(\.url), [firstURL, firstURL, secondURL])
        XCTAssertEqual(plan.requests.map(\.resumeData), [old, old, nil])
        XCTAssertEqual(try Data(contentsOf: firstResume), old)
        XCTAssertEqual(store.selectedDownloadSource, .modelScope)
        XCTAssertEqual(store.downloadSourceChoice, .automatic)
        XCTAssertEqual(store.failedDownloadSource, .modelScope)
        XCTAssertFalse(store.isInstalled(.light))
    }

    @MainActor
    func testAllUnavailableNeverStartsFullDownload() async throws {
        let plan = DownloadTestPlan([])
        let store = ModelStore(modelsDirectory: try temporaryDirectory(), defaults: isolatedDefaults(), transferFactory: plan.factory,
            sourceProbe: { _, _, _ in throw URLError(.serverCertificateUntrusted) }, retryDelay: {})
        await store.download(.standard)
        XCTAssertTrue(plan.requests.isEmpty)
        XCTAssertNil(store.downloadingModel)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.errorDetails?.contains("host=huggingface.co") == true)
        XCTAssertTrue(store.errorDetails?.contains("host=modelscope.cn") == true)
        XCTAssertFalse(store.errorDetails?.contains("Hy-MT") == true)
    }

    @MainActor
    func testManualChoiceSkipsProbes() async throws {
        let plan = DownloadTestPlan([.failure(ModelStoreError.httpStatus(503))])
        let count = DownloadTestCounter()
        let store = ModelStore(modelsDirectory: try temporaryDirectory(), defaults: isolatedDefaults(), transferFactory: plan.factory,
            sourceProbe: { _, source, _ in count.increment(); return .init(source: source, sampledBytes: 1, elapsed: 1) }, retryDelay: {})
        store.downloadSourceChoice = .modelScope
        await store.download(.light)
        XCTAssertEqual(count.value, 0)
        XCTAssertEqual(plan.requests.map(\.url), [TranslationModel.light.downloadURL(for: .modelScope)])
    }

    @MainActor
    func testCancelDuringAutomaticSelectionDoesNotStartDownload() async throws {
        let started = expectation(description: "probe started")
        started.expectedFulfillmentCount = 2
        let plan = DownloadTestPlan([])
        let store = ModelStore(modelsDirectory: try temporaryDirectory(), defaults: isolatedDefaults(), transferFactory: plan.factory,
            sourceProbe: { _, source, _ in
                started.fulfill()
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return .init(source: source, sampledBytes: 1, elapsed: 1)
            }, retryDelay: {})
        let operation = Task { await store.download(.light) }
        await fulfillment(of: [started], timeout: 2)
        store.cancelDownload()
        await operation.value
        XCTAssertTrue(plan.requests.isEmpty)
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.downloadingModel)
        XCTAssertNotNil(store.statusMessage)
    }

    @MainActor
    func testAutomaticDoesNotFallbackAfterInvalidDownloadedContent() async throws {
        let plan = DownloadTestPlan([.file(Data("wrong contents".utf8))])
        let store = ModelStore(modelsDirectory: try temporaryDirectory(), defaults: isolatedDefaults(), transferFactory: plan.factory,
            sourceProbe: { _, source, _ in .init(source: source, sampledBytes: 100, elapsed: source == .modelScope ? 0.1 : 1) }, retryDelay: {})
        await store.download(.light)
        XCTAssertEqual(plan.requests.count, 1)
        XCTAssertEqual(store.failedDownloadSource, .modelScope)
        XCTAssertFalse(store.isInstalled(.light))
    }

    @MainActor
    func testExplicitSourceRetriesOnlyItAndNeverUsesOfficialLegacyResume() async throws {
        let directory = try temporaryDirectory()
        let legacy = ModelDownloadResumeFiles.legacyURL(directory: directory, model: .standard)
        let old = Data("official legacy progress".utf8)
        try old.write(to: legacy)
        let own = ModelDownloadResumeFiles.url(directory: directory, model: .standard,
                                               source: TranslationModel.standard.downloadURL(for: .modelScope))
        let ownData = Data("modelscope progress".utf8)
        try ownData.write(to: own)
        let plan = DownloadTestPlan([.failure(URLError(.secureConnectionFailed)),
                                     .failure(URLError(.secureConnectionFailed))])
        let store = ModelStore(modelsDirectory: directory, defaults: isolatedDefaults(),
                               transferFactory: plan.factory, retryDelay: {})
        await store.download(.standard, from: .modelScope)
        XCTAssertEqual(plan.requests.map(\.url), Array(repeating: TranslationModel.standard.downloadURL(for: .modelScope), count: 2))
        XCTAssertEqual(plan.requests.map(\.resumeData), [ownData, ownData])
        XCTAssertEqual(try Data(contentsOf: legacy), old)
        XCTAssertEqual(try Data(contentsOf: own), ownData)
        XCTAssertEqual(store.failedDownloadModel, .standard)
        XCTAssertEqual(store.failedDownloadSource, .modelScope)
        XCTAssertEqual(store.errorDetails, "domain=NSURLErrorDomain; code=-1200; host=modelscope.cn")
        XCTAssertNil(store.downloadingModel)
    }

    @MainActor
    func testAlternativeStartsFreshWhenOnlyOfficialResumeExistsAndDeleteRemovesBothSources() async throws {
        let directory = try temporaryDirectory()
        let old = Data("official progress".utf8)
        let legacy = ModelDownloadResumeFiles.legacyURL(directory: directory, model: .light)
        try old.write(to: legacy)
        let paths = ModelDownloadSource.allCases.map {
            ModelDownloadResumeFiles.url(directory: directory, model: .light,
                                         source: TranslationModel.light.downloadURL(for: $0))
        }
        try old.write(to: paths[0])
        let plan = DownloadTestPlan([.failure(URLError(.notConnectedToInternet))])
        let store = ModelStore(modelsDirectory: directory, defaults: isolatedDefaults(),
                               transferFactory: plan.factory, retryDelay: {})
        await store.download(.light, from: .modelScope)
        XCTAssertEqual(plan.requests.count, 1)
        XCTAssertNil(plan.requests[0].resumeData)
        XCTAssertEqual(try Data(contentsOf: legacy), old)
        XCTAssertEqual(try Data(contentsOf: paths[0]), old)
        try Data("independent alternative progress".utf8).write(to: paths[1])
        let other = ModelDownloadResumeFiles.url(directory: directory, model: .standard,
                                                source: TranslationModel.standard.downloadURL(for: .modelScope))
        try Data("other model".utf8).write(to: other)
        try store.delete(.light)
        for removed in [legacy] + paths { XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path)) }
        XCTAssertEqual(try Data(contentsOf: other), Data("other model".utf8))
    }

    @MainActor
    func testUnverifiedOrPartialFilesAreNeverReady() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent(TranslationModel.light.filename)
        try Data("not a model".utf8).write(to: file)
        try Data("partial".utf8).write(to: file.appendingPathExtension("partial"))
        let store = ModelStore(modelsDirectory: directory, defaults: isolatedDefaults())
        XCTAssertFalse(store.isInstalled(.light))
        XCTAssertNil(store.modelURL(for: .light))
        XCTAssertTrue(store.installedModels.isEmpty)
    }

    @MainActor
    func testRejectedImportDoesNotOverwriteExistingFileOrOtherModels() async throws {
        let directory = try temporaryDirectory()
        let existing = directory.appendingPathComponent(TranslationModel.light.filename)
        let other = directory.appendingPathComponent(TranslationModel.standard.filename)
        let source = directory.appendingPathComponent("incorrect.gguf")
        try Data("existing".utf8).write(to: existing)
        try Data("other".utf8).write(to: other)
        try Data("wrong".utf8).write(to: source)
        let store = ModelStore(modelsDirectory: directory, defaults: isolatedDefaults())
        do {
            try await store.importModel(from: source, as: .light)
            XCTFail("Invalid model must fail import")
        } catch {
            guard case ModelStoreError.sizeMismatch = error else { return XCTFail("Wrong failure: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: existing), Data("existing".utf8))
        XCTAssertEqual(try Data(contentsOf: other), Data("other".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("wrong".utf8))
        XCTAssertNil(store.downloadingModel)
        XCTAssertNil(store.downloadProgress)
        XCTAssertNotNil(store.errorMessage)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(leftovers.contains { $0.hasSuffix(".partial") })
    }

    @MainActor
    func testDeleteOnlyRemovesTheSpecifiedModel() throws {
        let directory = try temporaryDirectory()
        let unrelated = directory.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: unrelated)
        for model in TranslationModel.allCases {
            try Data("model".utf8).write(to: directory.appendingPathComponent(model.filename))
        }
        let store = ModelStore(modelsDirectory: directory, defaults: isolatedDefaults())
        try store.delete(.light)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(TranslationModel.light.filename).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(TranslationModel.standard.filename).path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
    }

    @MainActor
    func testNetworkFailureResetsBusyStateWithoutMarkingReady() async throws {
        let directory = try temporaryDirectory()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineModelURLProtocol.self]
        let store = ModelStore(modelsDirectory: directory, defaults: isolatedDefaults(), sessionConfiguration: configuration)
        await store.download(.light, from: .huggingFace)
        XCTAssertNil(store.downloadingModel)
        XCTAssertNil(store.downloadProgress)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.isInstalled(.light))
        XCTAssertNil(store.modelURL(for: .light))
    }

    @MainActor
    func testVerifiedRealModelImportReceiptAndTamperDetection() async throws {
        // No network in tests. This integration case runs when the official fixture was
        // explicitly downloaded into the developer cache; ordinary CI safely skips it.
        let source = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/HaHaTranslateDevelopment/\(TranslationModel.light.filename)")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("Official offline model fixture is not cached")
        }
        let directory = try temporaryDirectory()
        let defaults = isolatedDefaults()
        let store = ModelStore(modelsDirectory: directory, defaults: defaults)
        try await store.importModel(from: source, as: .light)
        XCTAssertTrue(store.isInstalled(.light))
        XCTAssertEqual(store.installedModels, [.light])
        let installed = try XCTUnwrap(store.modelURL(for: .light))
        let relaunched = ModelStore(modelsDirectory: directory, defaults: defaults)
        XCTAssertTrue(relaunched.isInstalled(.light))
        let handle = try FileHandle(forWritingTo: installed)
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(1)], ofItemAtPath: installed.path)
        XCTAssertFalse(relaunched.isInstalled(.light))
        XCTAssertNil(relaunched.modelURL(for: .light))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    @MainActor
    func testTransientTLSFailureRetriesOnceThenReturnsSmallFixture() async throws {
        let directory = try temporaryDirectory()
        let bytes = Data("small verified transport fixture".utf8)
        let plan = DownloadTestPlan([.failure(URLError(.secureConnectionFailed)), .file(bytes)])
        let retries = DownloadTestCounter()
        let runner = makeRunner(plan, retryDelay: { retries.increment() })
        let result = try await runner.download(from: testSource,
            destination: directory.appendingPathComponent("file.partial"),
            resumeFile: directory.appendingPathComponent("resume"), expectedSize: Int64(bytes.count))
        XCTAssertEqual(try Data(contentsOf: result), bytes)
        XCTAssertEqual(plan.requests.count, 2)
        XCTAssertTrue(plan.requests.allSatisfy { $0.url == testSource && $0.resumeData == nil })
        XCTAssertEqual(retries.value, 1)
    }

    @MainActor
    func testTransientRetryLimitForEachAllowedError() async throws {
        for code in [URLError.secureConnectionFailed, .timedOut, .networkConnectionLost, .cannotConnectToHost] {
            let directory = try temporaryDirectory()
            let plan = DownloadTestPlan([.failure(URLError(code)), .failure(URLError(code)), .file(Data("unused".utf8))])
            let retries = DownloadTestCounter()
            let runner = makeRunner(plan, retryDelay: { retries.increment() })
            do {
                _ = try await runner.download(from: testSource, destination: directory.appendingPathComponent("partial"),
                    resumeFile: directory.appendingPathComponent("resume"), expectedSize: 1)
                XCTFail("Expected the second transport failure")
            } catch { XCTAssertEqual((ModelDownloadErrorPolicy.underlying(error) as NSError).code, code.rawValue) }
            XCTAssertEqual(plan.requests.count, 2)
            XCTAssertEqual(retries.value, 1)
        }
    }

    @MainActor
    func testCertificateFailuresNeverRetryOrDiscardSavedProgress() async throws {
        var errors: [Error] = [URLError.serverCertificateHasBadDate, .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
            .clientCertificateRejected, .clientCertificateRequired].map { URLError($0) }
        errors.append(NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -9812)]))
        for error in errors {
            let directory = try temporaryDirectory()
            let resume = directory.appendingPathComponent("resume")
            let old = Data("retained progress".utf8)
            try old.write(to: resume)
            let plan = DownloadTestPlan([.failure(error), .file(Data("must not be requested".utf8))])
            let retries = DownloadTestCounter()
            let runner = makeRunner(plan, retryDelay: { retries.increment() })
            do {
                _ = try await runner.download(from: testSource, destination: directory.appendingPathComponent("partial"),
                    resumeFile: resume, expectedSize: 1)
                XCTFail("Certificate failure must propagate")
            } catch { XCTAssertTrue(ModelDownloadErrorPolicy.isCertificateFailure(error)) }
            XCTAssertEqual(plan.requests.count, 1)
            XCTAssertEqual(retries.value, 0)
            XCTAssertEqual(try Data(contentsOf: resume), old)
        }
    }

    @MainActor
    func testTLSResumeRetryUsesNewestProgressAndRetainsItOnFinalFailure() async throws {
        let directory = try temporaryDirectory()
        let resume = directory.appendingPathComponent("resume")
        let old = Data("old progress".utf8), newest = Data("newer progress".utf8)
        try old.write(to: resume)
        let failure = ModelDownloadFailure(underlying: URLError(.secureConnectionFailed),
                                          resumeData: newest, serverHost: "cdn.example.test")
        let plan = DownloadTestPlan([.failure(failure), .failure(URLError(.secureConnectionFailed))])
        let runner = makeRunner(plan)
        do {
            _ = try await runner.download(from: testSource, destination: directory.appendingPathComponent("partial"),
                resumeFile: resume, expectedSize: 1)
            XCTFail("Expected final failure")
        } catch { XCTAssertEqual((ModelDownloadErrorPolicy.underlying(error) as NSError).code, NSURLErrorSecureConnectionFailed) }
        XCTAssertEqual(plan.requests.map(\.resumeData), [old, newest])
        XCTAssertEqual(try Data(contentsOf: resume), newest)
    }

    @MainActor
    func testTLSWithoutNewProgressAndOfflineFailureKeepOriginalResume() async throws {
        for code in [URLError.secureConnectionFailed, .notConnectedToInternet] {
            let directory = try temporaryDirectory()
            let resume = directory.appendingPathComponent("resume")
            let old = Data("do not discard".utf8)
            try old.write(to: resume)
            let plan = DownloadTestPlan([.failure(URLError(code)), .failure(URLError(code))])
            let runner = makeRunner(plan)
            do {
                _ = try await runner.download(from: testSource, destination: directory.appendingPathComponent("partial"),
                    resumeFile: resume, expectedSize: 1)
                XCTFail("Expected failure")
            } catch {}
            XCTAssertEqual(plan.requests.count, code == .secureConnectionFailed ? 2 : 1)
            XCTAssertTrue(plan.requests.allSatisfy { $0.resumeData == old })
            XCTAssertEqual(try Data(contentsOf: resume), old)
        }
    }

    @MainActor
    func testKnownInvalidResumeRestartsCleanWithoutDelay() async throws {
        let errors: [Error] = [ModelStoreError.httpStatus(403), ModelStoreError.httpStatus(416),
            URLError(.fileDoesNotExist), URLError(.cannotOpenFile), URLError(.unsupportedURL)]
        for error in errors {
            let directory = try temporaryDirectory()
            let resume = directory.appendingPathComponent("resume")
            let old = Data("invalid resume".utf8), bytes = Data("complete fixture".utf8)
            try old.write(to: resume)
            let failed = ModelDownloadFailure(underlying: error, resumeData: Data("also invalid".utf8), serverHost: nil)
            let plan = DownloadTestPlan([.failure(failed), .file(bytes)])
            let retries = DownloadTestCounter()
            let runner = makeRunner(plan, retryDelay: { retries.increment() })
            let result = try await runner.download(from: testSource, destination: directory.appendingPathComponent("partial"),
                resumeFile: resume, expectedSize: Int64(bytes.count))
            XCTAssertEqual(try Data(contentsOf: result), bytes)
            XCTAssertEqual(plan.requests.count, 2)
            XCTAssertEqual(plan.requests[0].resumeData, old)
            XCTAssertNil(plan.requests[1].resumeData)
            XCTAssertEqual(retries.value, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: resume.path))
        }
    }

    @MainActor
    func testFailedCleanRestartDoesNotLoop() async throws {
        let directory = try temporaryDirectory(), old = Data("old".utf8)
        let resume = directory.appendingPathComponent("resume")
        try old.write(to: resume)
        let plan = DownloadTestPlan([.failure(ModelStoreError.httpStatus(416)),
                                     .failure(ModelStoreError.httpStatus(416)), .file(Data())])
        let runner = makeRunner(plan)
        do {
            _ = try await runner.download(from: testSource, destination: directory.appendingPathComponent("partial"),
                resumeFile: resume, expectedSize: 1)
            XCTFail("Expected HTTP failure")
        } catch {
            guard case ModelStoreError.httpStatus(416) = ModelDownloadErrorPolicy.underlying(error) else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(plan.requests.count, 2)
        XCTAssertNil(plan.requests[1].resumeData)
    }

    @MainActor
    func testCancellationDuringRetryDelayStartsNoFurtherRequestAndClearsBusyState() async throws {
        let directory = try temporaryDirectory()
        let waiting = expectation(description: "entered retry delay")
        let fresh = Data("fresh resume returned by failed request".utf8)
        let failure = ModelDownloadFailure(underlying: URLError(.timedOut), resumeData: fresh, serverHost: "cdn.example.test")
        let plan = DownloadTestPlan([.failure(failure), .file(Data("must not run".utf8))])
        let store = ModelStore(modelsDirectory: directory, defaults: isolatedDefaults(), transferFactory: plan.factory,
                              retryDelay: { waiting.fulfill(); try await Task.sleep(nanoseconds: 10_000_000_000) })
        let operation = Task { await store.download(.standard, from: .huggingFace) }
        await fulfillment(of: [waiting], timeout: 2)
        store.cancelDownload()
        await operation.value
        XCTAssertEqual(plan.requests.count, 1)
        XCTAssertNil(store.downloadingModel)
        XCTAssertNil(store.downloadProgress)
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.errorDetails)
        XCTAssertNil(store.failedDownloadModel)
        XCTAssertNil(store.failedDownloadSource)
        let resume = ModelDownloadResumeFiles.url(directory: directory, model: .standard,
                                                  source: TranslationModel.standard.downloadURLs[0])
        XCTAssertEqual(try Data(contentsOf: resume), fresh)
    }

    @MainActor
    func testCancellationOfActiveTransportPersistsItsFreshResumeBeforeReturning() async throws {
        let directory = try temporaryDirectory()
        let waiting = expectation(description: "transport awaits cancellation")
        let fresh = Data("resume delivered by cancellation".utf8)
        let plan = DownloadTestPlan([.waitForCancellation(fresh)], onWaiting: { waiting.fulfill() })
        let store = ModelStore(modelsDirectory: directory, defaults: isolatedDefaults(), transferFactory: plan.factory,
                               retryDelay: {})
        let operation = Task { await store.download(.light, from: .huggingFace) }
        await fulfillment(of: [waiting], timeout: 2)
        store.cancelDownload()
        await operation.value
        let resume = ModelDownloadResumeFiles.url(directory: directory, model: .light,
                                                  source: TranslationModel.light.downloadURLs[0])
        XCTAssertEqual(try Data(contentsOf: resume), fresh)
        XCTAssertNil(store.downloadingModel)
        XCTAssertNil(store.failedDownloadModel)
        XCTAssertNil(store.failedDownloadSource)
        XCTAssertNil(store.errorDetails)
        XCTAssertEqual(plan.requests.count, 1)
    }

    func testInsecureRedirectFailureWinsOverHTTPAndFrameworkCancellation() {
        var outcome = ModelDownloadOutcome()
        outcome.record(.failure(ModelStoreError.insecureRedirect))
        outcome.record(.failure(ModelStoreError.httpStatus(302)))
        outcome.record(.success(URL(fileURLWithPath: "/unused")))
        for completionError in [nil, URLError(.cancelled), URLError(.secureConnectionFailed)] {
            let result = outcome.completed(error: completionError, userCancelled: false)
            XCTAssertThrowsError(try result.get()) {
                guard case ModelStoreError.insecureRedirect = $0 else { return XCTFail("Policy error was overwritten: \($0)") }
            }
        }
        XCTAssertThrowsError(try outcome.completed(error: nil, userCancelled: true).get()) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    @MainActor
    func testTLSFailureDetailsAreRedactedAndFailedModelIsExact() async throws {
        let directory = try temporaryDirectory()
        let secretURL = URL(string: "https://user:password@cdn.example.test/private.gguf?token=PRIVATE_TOKEN#secret")!
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed,
                            userInfo: [NSURLErrorFailingURLErrorKey: secretURL,
                                       NSLocalizedDescriptionKey: "PRIVATE_TOKEN and source text must not be displayed"])
        let plan = DownloadTestPlan([.failure(error), .failure(error), .file(Data())])
        let store = ModelStore(modelsDirectory: directory, defaults: isolatedDefaults(), transferFactory: plan.factory, retryDelay: {})
        XCTAssertEqual(store.selectedModel, .light)
        await store.download(.standard, from: .huggingFace)
        XCTAssertEqual(plan.requests.count, 2)
        XCTAssertEqual(store.failedDownloadModel, .standard)
        XCTAssertEqual(store.failedDownloadSource, .huggingFace)
        XCTAssertEqual(store.errorDetails, "domain=NSURLErrorDomain; code=-1200; host=cdn.example.test")
        XCTAssertFalse(try XCTUnwrap(store.errorMessage).contains("PRIVATE_TOKEN"))
        XCTAssertNil(store.downloadingModel)
        XCTAssertNil(store.downloadProgress)
        XCTAssertFalse(store.isInstalled(.standard))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".verified.json") })
    }

    func testCancellationAndTransientCodesRequireTheirDomain() {
        let foreign = NSError(domain: "UnrelatedComponent", code: NSURLErrorCancelled)
        XCTAssertFalse(ModelDownloadErrorPolicy.isCancellation(foreign))
        XCTAssertFalse(ModelDownloadErrorPolicy.isTransient(NSError(domain: "UnrelatedComponent", code: NSURLErrorTimedOut)))
        XCTAssertEqual(ModelDownloadDiagnostics.details(for: foreign), "domain=UnrelatedComponent; code=-999; host=-")
        let hostile = NSError(domain: "https://example.test/?token=secret", code: 4)
        XCTAssertEqual(ModelDownloadDiagnostics.details(for: hostile), "domain=UnknownError; code=4; host=-")
    }

    @MainActor
    func testOldOfficialResumeMigratesToSourceIsolatedPath() async throws {
        let directory = try temporaryDirectory()
        let legacy = ModelDownloadResumeFiles.legacyURL(directory: directory, model: .light)
        let data = Data("legacy official progress".utf8)
        try data.write(to: legacy)
        let plan = DownloadTestPlan([.failure(URLError(.notConnectedToInternet))])
        let store = ModelStore(modelsDirectory: directory, defaults: isolatedDefaults(), transferFactory: plan.factory, retryDelay: {})
        await store.download(.light, from: .huggingFace)
        XCTAssertEqual(plan.requests.first?.resumeData, data)
        let current = ModelDownloadResumeFiles.url(directory: directory, model: .light,
                                                   source: TranslationModel.light.downloadURLs[0])
        XCTAssertEqual(try Data(contentsOf: current), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testResumePathsIsolateTheCompleteSourceURLWithoutStoringItInFilename() throws {
        let directory = try temporaryDirectory()
        let urls = ["https://a.example.test/model?version=1", "https://a.example.test/model?version=2", "https://b.example.test/model?version=1"]
        let names = urls.map {
            ModelDownloadResumeFiles.url(directory: directory, model: .light, source: URL(string: $0)!).lastPathComponent
        }
        XCTAssertEqual(Set(names).count, 3)
        XCTAssertTrue(names.allSatisfy { !$0.contains("example") && !$0.contains("?") && !$0.contains("version") })
    }

    private var testSource: URL { URL(string: "https://download.example.test/pinned/fixture.gguf")! }
    @MainActor private func makeRunner(_ plan: DownloadTestPlan,
                                      retryDelay: @escaping ModelDownloadRetryDelay = {}) -> ModelDownloadRunner {
        ModelDownloadRunner(configuration: .ephemeral, factory: plan.factory, retryDelay: retryDelay)
    }

}

private final class OfflineModelURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}


private final class DownloadTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

private final class DownloadTestPlan: @unchecked Sendable {
    enum Step { case failure(Error), file(Data), waitForCancellation(Data) }
    struct Request { let url: URL; let resumeData: Data? }
    private let lock = NSLock()
    private var steps: [Step]
    private var recorded: [Request] = []
    let onWaiting: @Sendable () -> Void
    init(_ steps: [Step], onWaiting: @escaping @Sendable () -> Void = {}) {
        self.steps = steps; self.onWaiting = onWaiting
    }
    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return recorded }
    func take(url: URL, resumeData: Data?) -> Step {
        lock.lock(); defer { lock.unlock() }
        recorded.append(.init(url: url, resumeData: resumeData))
        guard !steps.isEmpty else { return .failure(NSError(domain: "UnexpectedDownloadAttempt", code: recorded.count)) }
        return steps.removeFirst()
    }
    @MainActor var factory: ModelDownloadTransportFactory {
        { destination, _, _ in DownloadTestTransport(plan: self, destination: destination) }
    }
}

private final class DownloadTestTransport: ModelDownloadTransport, @unchecked Sendable {
    private let plan: DownloadTestPlan
    private let destination: URL
    private let lock = NSLock()
    private var waiter: CheckedContinuation<URL, Error>?
    private var cancelled = false
    private var cancellationResume: Data?
    init(plan: DownloadTestPlan, destination: URL) { self.plan = plan; self.destination = destination }
    func download(from url: URL, resumeData: Data?, expectedSize: Int64) async throws -> URL {
        switch plan.take(url: url, resumeData: resumeData) {
        case .failure(let error): throw error
        case .file(let bytes): try bytes.write(to: destination); return destination
        case .waitForCancellation(let data):
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.lock(); cancellationResume = data
                    let alreadyCancelled = cancelled
                    if !alreadyCancelled { waiter = continuation }
                    lock.unlock()
                    if alreadyCancelled { continuation.resume(throwing: cancellationError(data)) }
                    plan.onWaiting()
                }
            } onCancel: { self.cancel() }
        }
    }
    func cancel() {
        lock.lock(); cancelled = true
        let continuation = waiter; waiter = nil
        let data = cancellationResume
        lock.unlock()
        continuation?.resume(throwing: cancellationError(data))
    }
    private func cancellationError(_ data: Data?) -> ModelDownloadFailure {
        ModelDownloadFailure(underlying: URLError(.cancelled), resumeData: data, serverHost: nil)
    }
}
