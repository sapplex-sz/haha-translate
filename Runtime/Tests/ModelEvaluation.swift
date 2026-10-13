import Foundation

@_silgen_name("haha_test_current_rss")
private func currentRSS() -> UInt64

private struct Corpus: Decodable { let cases: [Sample] }
private struct Sample: Decodable {
    let id: String
    let category: String
    let sourceLanguage: String
    let targetLanguage: String
    let text: String
    let reviewFacts: String
    let glossary: [String: String]
    let preserveLiterals: [String]
}
private final class EvaluationStream: @unchecked Sendable {
    private var text = ""
    private let lock = NSLock()
    func append(_ value: String) { lock.withLock { text += value } }
    func value() -> String { lock.withLock { text } }
}
private struct Model { let id: String; let url: URL }

@main
enum ModelEvaluation {
    static func main() async throws {
        guard CommandLine.arguments.count == 5 else {
            fatalError("Usage: model-evaluation inputs.json output.jsonl light.gguf standard.gguf")
        }
        let inputs = URL(fileURLWithPath: CommandLine.arguments[1])
        let destination = URL(fileURLWithPath: CommandLine.arguments[2])
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: inputs))
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }
        func write(_ value: [String: Any]) throws {
            var bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
            bytes.append(0x0a)
            try file.write(contentsOf: bytes)
        }
        let models = [Model(id: "light", url: URL(fileURLWithPath: CommandLine.arguments[3])),
                      Model(id: "standard", url: URL(fileURLWithPath: CommandLine.arguments[4]))]
        let engine = LocalTranslationEngine()
        try write(["event": "metadata", "date": "2026-10-03", "runtime": LocalTranslationEngine.runtimeVersion,
                   "hardware": "Apple M4 / 32 GB", "system": ProcessInfo.processInfo.operatingSystemVersionString,
                   "caseCount": corpus.cases.count, "chunkLimit": 700, "baselineRSS": currentRSS(),
                   "sourceLanguageMode": "automatic", "scoring": "No external judge; literal/numeric checks are flags only"])
        for model in models {
            for sample in corpus.cases {
                let start = Date()
                var output = ""
                var chunkRecords: [[String: Any]] = []
                var status = "ok"
                var errorDescription = ""
                for chunk in TextProcessing.chunks(sample.text, limit: 700) {
                    let stream = EvaluationStream()
                    let chunkStart = Date()
                    do {
                        let returned = try await engine.translate(text: chunk.text, sourceLanguage: nil,
                            targetLanguage: sample.targetLanguage, modelURL: model.url,
                            glossary: sample.glossary, onToken: { stream.append($0) })
                        output += returned + chunk.separator
                        chunkRecords.append(["source": chunk.text, "separator": chunk.separator,
                            "rawOutput": stream.value(), "returnedOutput": returned,
                            "seconds": Date().timeIntervalSince(chunkStart),
                            "streamMatches": stream.value().trimmingCharacters(in: .whitespacesAndNewlines) == returned])
                    } catch {
                        status = "error"
                        errorDescription = error.localizedDescription
                        chunkRecords.append(["source": chunk.text, "rawOutput": stream.value(),
                                             "seconds": Date().timeIntervalSince(chunkStart)])
                        break
                    }
                }
                let missingLiterals = sample.preserveLiterals.filter { !output.contains($0) }
                try write(["event": "translation", "model": model.id, "id": sample.id,
                    "category": sample.category, "sourceLanguage": sample.sourceLanguage,
                    "targetLanguage": sample.targetLanguage, "source": sample.text,
                    "reviewFacts": sample.reviewFacts, "glossary": sample.glossary,
                    "output": output, "chunks": chunkRecords, "status": status,
                    "error": errorDescription, "seconds": Date().timeIntervalSince(start),
                    "rssBytes": currentRSS(), "missingLiterals": missingLiterals,
                    "numericFlags": TextProcessing.missingNumbers(source: sample.text, translation: output)])
                print("\(model.id) \(sample.id) \(status)")
            }
            await engine.unload()
            try write(["event": "unload", "phase": "quality", "model": model.id, "rssBytes": currentRSS()])
        }
        // Real transitions within the same engine object.
        for model in [models[0], models[1], models[0]] {
            let before = currentRSS()
            let start = Date()
            let output = try await engine.translate(text: "The local backup is complete. Keep the original file.",
                sourceLanguage: nil, targetLanguage: "Chinese", modelURL: model.url, onToken: { _ in })
            try write(["event": "modelSwitch", "model": model.id, "output": output,
                       "seconds": Date().timeIntervalSince(start), "rssBefore": before, "rssBytes": currentRSS()])
        }
        await engine.unload()
        for model in models {
            _ = try await engine.translate(text: "Good morning.", sourceLanguage: nil,
                targetLanguage: "Chinese", modelURL: model.url, onToken: { _ in })
            let baseline = currentRSS()
            for iteration in 1...20 {
                let start = Date()
                let request = Task {
                    try await engine.translate(text: String(repeating: "This synthetic paragraph tests cancellation while the model processes input. ", count: 60),
                        sourceLanguage: nil, targetLanguage: "Chinese", modelURL: model.url, onToken: { _ in })
                }
                try await Task.sleep(for: .milliseconds(30))
                let mode = iteration.isMultiple(of: 2) ? "task.cancel" : "engine.cancel"
                if iteration.isMultiple(of: 2) { request.cancel() } else { await engine.cancel() }
                var cancellationStatus = "unexpectedSuccess"
                do { _ = try await request.value }
                catch is CancellationError { cancellationStatus = "cancelled" }
                catch { cancellationStatus = "error: \(error.localizedDescription)" }
                let cancelSeconds = Date().timeIntervalSince(start)
                let resumedStart = Date()
                var resumed = ""
                var resumedError = ""
                do {
                    resumed = try await engine.translate(text: "请保留原文件，不要删除备份。", sourceLanguage: nil,
                        targetLanguage: "English", modelURL: model.url, onToken: { _ in })
                } catch { resumedError = error.localizedDescription }
                try write(["event": "cancelCycle", "model": model.id, "iteration": iteration,
                    "mode": mode, "cancellationStatus": cancellationStatus, "cancelSeconds": cancelSeconds,
                    "resumedOutput": resumed, "resumedError": resumedError,
                    "resumeSeconds": Date().timeIntervalSince(resumedStart),
                    "baselineRSS": baseline, "rssBytes": currentRSS()])
                print("cancel \(model.id) \(iteration) \(cancellationStatus)")
            }
            await engine.unload()
            try write(["event": "unload", "phase": "stability", "model": model.id, "rssBytes": currentRSS()])
        }
        try write(["event": "complete", "rssBytes": currentRSS()])
    }
}
