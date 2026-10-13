import Foundation
import XCTest
@testable import HaHaCore

final class ModelSourceSelectionTests: XCTestCase {
    func testRanksThroughputIncludingConnectionLatencyAndRunsConcurrently() async throws {
        let start = ContinuousClock.now
        let ranked = try await ModelSourceSelector.rankedSources(for: .light, configuration: .ephemeral) { _, source, _ in
            try await Task.sleep(nanoseconds: 150_000_000)
            return .init(source: source, sampledBytes: source == .huggingFace ? 1_048_576 : 524_288,
                         elapsed: source == .huggingFace ? 4 : 1)
        }
        XCTAssertEqual(ranked, [.modelScope, .huggingFace])
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(280))
    }

    func testExcludesTLSFailureFromRankedSources() async throws {
        let ranked = try await ModelSourceSelector.rankedSources(for: .standard, configuration: .ephemeral) { _, source, _ in
            if source == .huggingFace { throw URLError(.secureConnectionFailed) }
            return .init(source: source, sampledBytes: 32_768, elapsed: 1)
        }
        XCTAssertEqual(ranked, [.modelScope])
    }

    func testCapsStreamingBodyWhenServerIgnoresRange() async throws {
        let result = try await probe(path: "ignore-range").run()
        XCTAssertEqual(result.sampledBytes, ModelSourceProbe.sampleLimit)
        XCTAssertGreaterThan(result.elapsed, 0)
        XCTAssertEqual(result.source, .modelScope)
    }

    func testRejectsResponseFromWrongFileAndTruncatedSample() async {
        for path in ["wrong-total", "tiny-body"] {
            do { _ = try await probe(path: path).run(); XCTFail("Invalid response accepted: \(path)") }
            catch { XCTAssertEqual((error as NSError).code, NSURLErrorBadServerResponse) }
        }
    }

    func testDeadlineStopsStalledServer() async {
        let start = ContinuousClock.now
        do { _ = try await probe(path: "stall", timeout: 0.1).run(); XCTFail("Expected timeout") }
        catch { XCTAssertEqual((error as NSError).code, NSURLErrorTimedOut) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testDeadlineCanMeasureSlowButAvailableRoute() async throws {
        let result = try await probe(path: "slow", timeout: 0.1).run()
        XCTAssertEqual(result.sampledBytes, 32_768)
        XCTAssertGreaterThanOrEqual(result.elapsed, 0.09)
    }

    func testCancellationStopsProbeBeforeDeadline() async {
        let probe = probe(path: "stall", timeout: 5)
        let task = Task { try await probe.run() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testRejectsInsecureInitialURL() async {
        let probe = ModelSourceProbe(source: .modelScope, url: URL(string: "http://example.test/model")!,
                                     expectedSize: TranslationModel.light.byteCount, configuration: .ephemeral)
        do { _ = try await probe.run(); XCTFail("Insecure source accepted") }
        catch { guard case ModelStoreError.insecureRedirect = error else { return XCTFail("Wrong error: \(error)") } }
    }

    private func probe(path: String, timeout: TimeInterval = 2) -> ModelSourceProbe {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProbeFixtureProtocol.self]
        return ModelSourceProbe(source: .modelScope, url: URL(string: "https://probe.example.test/\(path)")!,
                                 expectedSize: TranslationModel.light.byteCount, configuration: config, timeout: timeout)
    }
}

private final class ProbeFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.lastPathComponent
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-1048575")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        let total = TranslationModel.light.byteCount
        let status = path == "ignore-range" ? 200 : 206
        let end = path == "tiny-body" ? 1 : 1_048_575
        let headers = status == 200 ? ["Content-Length": "\(total)"] : [
            "Content-Length": "\(end + 1)", "Content-Range": "bytes 0-\(end)/\(path == "wrong-total" ? total + 1 : total)"]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        switch path {
        case "stall": return
        case "slow": client?.urlProtocol(self, didLoad: Data(repeating: 0, count: 32_768))
        case "tiny-body":
            client?.urlProtocol(self, didLoad: Data([0, 1]))
            client?.urlProtocolDidFinishLoading(self)
        default:
            client?.urlProtocol(self, didLoad: Data(repeating: 0, count: 2_097_152))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
