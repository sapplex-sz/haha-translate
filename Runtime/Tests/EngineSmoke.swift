import Foundation

private final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func append(_ text: String) { lock.withLock { value += text } }
    func snapshot() -> String { lock.withLock { value } }
}

@main
enum EngineSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Supply model path") }
        let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let engine = LocalTranslationEngine()
        let stream = StreamCollector()
        let start = Date()
        let text = try await engine.translate(text: "请在工作区中保存文件，价格是 99.50 元。",
            sourceLanguage: "Chinese", targetLanguage: "English", modelURL: modelURL,
            glossary: ["工作区": "workspace"], onToken: { stream.append($0) })
        precondition(text == stream.snapshot().trimmingCharacters(in: .whitespacesAndNewlines))
        precondition(text.contains("workspace") && text.contains("99.50"))
        print("SWIFT_TRANSLATION \(text)")
        print("SWIFT_SECONDS \(Date().timeIntervalSince(start))")
        let cancellationStart = Date()
        let pending = Task {
            try await engine.translate(text: String(repeating: "This paragraph tests cancellation while the model is processing its input. ", count: 70),
                sourceLanguage: nil, targetLanguage: "Chinese", modelURL: modelURL, onToken: { _ in })
        }
        try await Task.sleep(for: .milliseconds(30))
        await engine.cancel()
        do { _ = try await pending.value; fatalError("Cancelled request must throw") }
        catch is CancellationError { print("SWIFT_CANCEL_SECONDS \(Date().timeIntervalSince(cancellationStart))") }
        precondition(Date().timeIntervalSince(cancellationStart) < 3)
        let resumed = try await engine.translate(text: "Good morning.", sourceLanguage: nil,
            targetLanguage: "Chinese", modelURL: modelURL, onToken: { _ in })
        precondition(!resumed.isEmpty)
        print("SWIFT_RESUMED \(resumed)")
        await engine.unload()
        print("SWIFT_PASS")
    }
}
