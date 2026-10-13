import AppKit
import Combine
import SwiftUI

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case translate, history, glossary, models, settings
    var id: String { rawValue }
    var title: String {
        switch self { case .translate: return L("翻译"); case .history: return L("历史记录"); case .glossary: return L("我的术语"); case .models: return L("离线模型"); case .settings: return L("设置") }
    }
    var icon: String {
        switch self { case .translate: return "character.bubble"; case .history: return "clock.arrow.circlepath"; case .glossary: return "text.book.closed"; case .models: return "internaldrive"; case .settings: return "slider.horizontal.3" }
    }
}

private enum TranslationStatus {
    case ready, inputUpdated, preparing, completed, stopped, failed, stopping, unloaded, swapped, history
    case translating(segment: Int, total: Int)
    var title: String {
        switch self {
        case .ready: return ""
        case .inputUpdated: return ""
        case .preparing: return L("正在准备本地模型…")
        case .translating(let segment, let total):
            return total > 1 ? L("正在翻译第 %d / %d 段 · 全程本机", segment, total) : L("正在翻译 · 全程本机")
        case .completed: return L("翻译完成")
        case .stopped: return L("已停止，保留当前译文。")
        case .failed: return L("本次翻译未完成")
        case .stopping: return L("正在停止…")
        case .unloaded: return ""
        case .swapped: return ""
        case .history: return L("历史记录")
        }
    }
}

@MainActor final class AppState: ObservableObject {
    @Published var section: WorkspaceSection = .translate
    @Published var settingsPane: SettingsPane = .general
    @Published var input = "" {
        didSet {
            if input != oldValue && !isTranslating {
                output = ""; error = nil; numbersToReview = []; elapsed = nil
                translationStatus = input.isEmpty ? .ready : .inputUpdated
            }
        }
    }
    @Published var output = ""
    @Published var sourceLanguage: AppLanguage = .automatic { didSet { persistLanguagePreferences() } }
    @Published var targetLanguage: AppLanguage = .chinese { didSet { persistLanguagePreferences() } }
    @Published var translationMode: TranslationDirectionMode = .automaticPair { didSet { persistLanguagePreferences() } }
    @Published var pairLanguageA: AppLanguage = .chinese { didSet { persistLanguagePreferences() } }
    @Published var pairLanguageB: AppLanguage = .english { didSet { persistLanguagePreferences() } }
    // Compatibility for existing keyboard/menu actions and earlier UI bindings.
    var automaticDirection: Bool {
        get { translationMode == .automaticPair }
        set { translationMode = newValue ? .automaticPair : .fixedTarget }
    }
    @Published var isTranslating = false
    @Published var isMaintainingModel = false
    @Published private var resultLanguage: AppLanguage?
    @Published private var historicalLanguageFallback = ""
    @Published private var translationStatus: TranslationStatus = .ready
    var resultLanguageTitle: String { resultLanguage?.title ?? historicalLanguageFallback }
    var status: String { translationStatus.title }
    @Published var error: String?
    @Published private var numbersToReview: [String] = []
    var numberWarning: String? {
        numbersToReview.isEmpty ? nil : L("请核对译文中的数字：%@", numbersToReview.joined(separator: ", "))
    }
    @Published var elapsed: TimeInterval?
    @Published var isPinned = false
    @Published var historyEnabled = UserDefaults.standard.bool(forKey: "historyEnabled") {
        didSet { UserDefaults.standard.set(historyEnabled, forKey: "historyEnabled") }
    }
    @Published var keepWarmMinutes = max(1, UserDefaults.standard.integer(forKey: "keepWarmMinutes") == 0 ? 3 : UserDefaults.standard.integer(forKey: "keepWarmMinutes")) {
        didSet { UserDefaults.standard.set(keepWarmMinutes, forKey: "keepWarmMinutes") }
    }
    @Published var glossary: [GlossaryEntry] = []
    @Published var history: [HistoryEntry] = []
    @Published var toast: String?
    let models: ModelStore
    let engine = LocalTranslationEngine()
    var showMainWindow: (() -> Void)?
    var showQuickWindow: (() -> Void)?
    var dismissQuickWindow: (() -> Void)?
    var screenshotAction: (() -> Void)?
    var previousApplication: NSRunningApplication?
    private var work: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var currentRun = UUID()
    private var currentChunk: UUID?
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var localizationSubscription: AnyCancellable?
    private let dataDirectory: URL
    private let languageDefaults: UserDefaults
    private var isApplyingLanguagePreferences = true

    init(models: ModelStore, defaults: UserDefaults = .standard) {
        self.models = models
        languageDefaults = defaults
        dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HaHaTranslate", isDirectory: true)
        applyLanguagePreferences(TranslationLanguagePreferences.load(from: defaults))
        isApplyingLanguagePreferences = false
        languagePreferences.save(to: defaults)
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        glossary = load([GlossaryEntry].self, "glossary.json") ?? []
        history = load([HistoryEntry].self, "history.json") ?? []
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in Task { @MainActor in await self?.unload() } }
        pressure.resume(); memoryPressure = pressure
        localizationSubscription = AppLocalization.shared.$language.dropFirst()
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.error = nil; self?.toast = nil
            }
    }

    var actualTarget: AppLanguage {
        languagePreferences.resolvedTarget(detectedSource: sourceLanguage == .automatic ? AppLanguage.detect(input) : nil)
    }
    var canTranslate: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isTranslating && !isMaintainingModel }

    private var languagePreferences: TranslationLanguagePreferences {
        .init(mode: translationMode, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage,
              pairLanguageA: pairLanguageA, pairLanguageB: pairLanguageB)
    }
    private func applyLanguagePreferences(_ value: TranslationLanguagePreferences) {
        if sourceLanguage != value.sourceLanguage { sourceLanguage = value.sourceLanguage }
        if targetLanguage != value.targetLanguage { targetLanguage = value.targetLanguage }
        if translationMode != value.mode { translationMode = value.mode }
        if pairLanguageA != value.pairLanguageA { pairLanguageA = value.pairLanguageA }
        if pairLanguageB != value.pairLanguageB { pairLanguageB = value.pairLanguageB }
    }
    private func persistLanguagePreferences() {
        guard !isApplyingLanguagePreferences else { return }
        let value = languagePreferences.normalized()
        isApplyingLanguagePreferences = true
        applyLanguagePreferences(value)
        isApplyingLanguagePreferences = false
        value.save(to: languageDefaults)
    }

    func translate() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !isTranslating, !isMaintainingModel else { notify(L("正在释放模型，请稍后再试。")); return }
        output = ""; elapsed = nil; numbersToReview = []
        guard text.count <= TextProcessing.maximumCharacters else {
            error = L("一次最多翻译 12,000 个字符，请分次粘贴。原文已保留。"); return
        }
        guard let modelURL = models.modelURL(for: models.selectedModel) else {
            section = .models; error = L("先下载一个离线模型，即可开始翻译。"); showMainWindow?(); return
        }
        guard !isTranslating else { return }
        idleTask?.cancel()
        error = nil; numbersToReview = []; output = ""; elapsed = nil
        isTranslating = true; translationStatus = .preparing
        let target = actualTarget
        resultLanguage = target
        let source = sourceLanguage == .automatic ? nil : sourceLanguage.modelName
        let run = UUID(); currentRun = run
        let entries = glossary.filter { !$0.source.isEmpty && text.localizedCaseInsensitiveContains($0.source) }
        work = Task { [weak self] in
            guard let self else { return }
            let start = Date()
            do {
                let chunks = TextProcessing.chunks(text)
                var full = ""
                for (index, chunk) in chunks.enumerated() {
                    try Task.checkCancellation()
                    guard currentRun == run else { return }
                    translationStatus = .translating(segment: index + 1, total: chunks.count)
                    let prefix = full
                    let chunkID = UUID()
                    self.currentChunk = chunkID
                    let applicable = entries.filter { chunk.text.localizedCaseInsensitiveContains($0.source) }.prefix(12)
                    let terms = Dictionary(applicable.map { ($0.source, $0.target) }, uniquingKeysWith: { _, latest in latest })
                    output = prefix
                    let translated = try await engine.translate(text: chunk.text, sourceLanguage: source, targetLanguage: target.modelName, modelURL: modelURL, glossary: terms) { [weak self] delta in
                        Task { @MainActor in
                            guard let self, self.currentRun == run, self.currentChunk == chunkID, self.isTranslating else { return }
                            self.output += delta
                        }
                    }
                    self.currentChunk = nil
                    try Task.checkCancellation()
                    full = prefix + translated + (index < chunks.count - 1 ? chunk.separator : "")
                    output = full
                }
                guard currentRun == run else { return }
                output = full.trimmingCharacters(in: .whitespacesAndNewlines)
                elapsed = Date().timeIntervalSince(start)
                translationStatus = .completed
                let missing = TextProcessing.missingNumbers(source: text, translation: output)
                numbersToReview = missing
                if historyEnabled {
                    history.insert(.init(source: text, translation: output, language: target.modelName, languageCode: target.rawValue), at: 0)
                    history = Array(history.prefix(100))
                    persist(history, "history.json")
                }
            } catch is CancellationError {
                if currentRun == run { translationStatus = .stopped }
            } catch {
                if currentRun == run { self.error = error.localizedDescription; translationStatus = .failed }
            }
            if currentRun == run { isTranslating = false; scheduleUnload() }
        }
    }

    func cancel() {
        work?.cancel()
        translationStatus = .stopping
    }

    func unload() async {
        guard !isMaintainingModel else { return }
        isMaintainingModel = true
        defer { isMaintainingModel = false }
        idleTask?.cancel()
        if isTranslating { cancel(); await work?.value }
        await engine.unload()
        translationStatus = .unloaded
    }

    private func scheduleUnload() {
        idleTask?.cancel()
        let seconds = UInt64(keepWarmMinutes * 60)
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, let self, !isTranslating, !isMaintainingModel else { return }
            isMaintainingModel = true
            await engine.unload()
            isMaintainingModel = false
        }
    }

    func translateClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = L("剪贴板里没有文字。复制一段文字后再试。"); showMainWindow?(); return
        }
        receive(text)
    }
    func receive(_ text: String, rememberSource: Bool = true) {
        guard !isTranslating, !isMaintainingModel else { notify(L("正在处理当前任务，请稍后再试。")); return }
        if rememberSource { rememberApplication() }
        input = text; section = .translate; showQuickWindow?(); translate()
    }
    func rememberApplication() {
        if previousApplication?.isTerminated == true { previousApplication = nil }
        guard let app = NSWorkspace.shared.frontmostApplication, !app.isTerminated,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        previousApplication = app
    }
    func copy(returnToApp: Bool = false) {
        // Closing the panel is independent of whether its source app still exists.
        if returnToApp { dismissQuickWindow?() }
        guard !output.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(output, forType: .string)
        if returnToApp, let app = previousApplication, !app.isTerminated {
            app.activate(); notify(L("译文已复制，按 ⌘V 粘贴。"))
        } else { notify(L("译文已复制")) }
    }
    func notify(_ text: String) {
        toast = text
        Task { try? await Task.sleep(nanoseconds: 2_500_000_000); if self.toast == text { self.toast = nil } }
    }
    func swapLanguages() {
        guard !isTranslating else { return }
        let oldTarget = actualTarget
        let detectedSource = sourceLanguage == .automatic ? AppLanguage.detect(input) : sourceLanguage
        let oldSource = detectedSource == .automatic ? (oldTarget == pairLanguageA ? pairLanguageB : pairLanguageA) : detectedSource
        sourceLanguage = oldTarget; targetLanguage = oldSource; automaticDirection = false
        if !output.isEmpty {
            let oldInput = input
            input = output
            output = oldInput
            resultLanguage = oldSource
            translationStatus = .swapped
        }
    }
    func saveGlossary() { persist(glossary, "glossary.json") }
    func clearHistory() {
        do {
            let file = dataDirectory.appendingPathComponent("history.json")
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            history = []
        } catch { self.error = L("无法清除历史记录：%@", error.localizedDescription) }
    }
    func restore(_ item: HistoryEntry) {
        guard !isTranslating else { return }
        input = item.source; output = item.translation; elapsed = nil; error = nil; numbersToReview = []; section = .translate
        resultLanguage = item.resolvedLanguage
        historicalLanguageFallback = item.language
        translationStatus = .history
    }
    private func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: dataDirectory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    private func persist<T: Encodable>(_ value: T, _ name: String) {
        do { try JSONEncoder().encode(value).write(to: dataDirectory.appendingPathComponent(name), options: .atomic) }
        catch { self.error = L("本地保存失败：%@", error.localizedDescription) }
    }
}
