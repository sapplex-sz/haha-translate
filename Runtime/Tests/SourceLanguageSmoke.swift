import Foundation

private final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func append(_ text: String) { lock.withLock { value += text } }
    func snapshot() -> String { lock.withLock { value } }
}

@main
enum SourceLanguageSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count >= 2 else { fatalError("Supply verified model paths") }
        let engine = LocalTranslationEngine()
        var failures = [String]()
        for path in CommandLine.arguments.dropFirst() {
            let modelURL = URL(fileURLWithPath: path)
            let cases: [(String, String, String?, String, [String: String])] = [
                ("german-gift", "Gift", "German", "English", [:]),
                ("english-gift", "Gift", "English", "Chinese", [:]),
                ("german-sentence", "Das Gift darf nicht ins Wasser gelangen.", "German", "English", [:]),
                ("manual-sentence", "The meeting starts at 10:30 tomorrow. Please bring the 2026 budget report.", "English", "Chinese", [:]),
                ("automatic-sentence", "The meeting starts at 10:30 tomorrow. Please bring the 2026 budget report.", nil, "Chinese", [:]),
                ("manual-glossary", "请在工作区中保存文件，价格是 99.50 元。", "Chinese", "English", ["工作区": "workspace"]),
                ("automatic-glossary", "请在工作区中保存文件，价格是 99.50 元。", nil, "English", ["工作区": "workspace"])
            ]
            for (id, source, language, target, glossary) in cases {
                let collector = StreamCollector()
                let start = Date()
                let output = try await engine.translate(text: source, sourceLanguage: language,
                    targetLanguage: target, modelURL: modelURL, glossary: glossary,
                    onToken: { collector.append($0) })
                let streamMatches = output == collector.snapshot().trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = output.lowercased()
                let expectation: Bool
                switch id {
                case "german-gift": expectation = lower.contains("poison") || lower.contains("toxin")
                case "english-gift": expectation = output.contains("礼物") || output.contains("赠品")
                case "german-sentence": expectation = lower.contains("poison") && lower.contains("water") && lower.contains("not")
                case "manual-glossary", "automatic-glossary": expectation = lower.contains("workspace") && output.contains("99.50")
                default: expectation = output.contains("10:30") && output.contains("2026") && output.contains("明天") && output.contains("预算")
                }
                let record: [String: Any] = ["id": id, "model": modelURL.lastPathComponent,
                    "source": source, "sourceLanguage": language as Any? ?? NSNull(),
                    "targetLanguage": target, "glossary": glossary, "output": output,
                    "seconds": Date().timeIntervalSince(start), "streamMatches": streamMatches,
                    "expectationPassed": expectation]
                let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
                FileHandle.standardOutput.write(data + Data([10]))
                if !expectation || !streamMatches { failures.append("\(modelURL.lastPathComponent): \(id)") }
            }
            await engine.unload()
        }
        if !failures.isEmpty {
            throw NSError(domain: "SourceLanguageRegression", code: 1,
                userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: ", ")])
        }
    }
}
