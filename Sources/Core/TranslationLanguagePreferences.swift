import Foundation

enum TranslationDirectionMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case automaticPair, fixedTarget
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automaticPair: return L("自动双向")
        case .fixedTarget: return L("固定目标")
        }
    }
}

/// Language routing is independent of UI state and model inference.
struct TranslationLanguagePreferences: Codable, Equatable, Sendable {
    static let storageKey = "translationLanguagePreferences.v1"
    var mode: TranslationDirectionMode = .automaticPair
    var sourceLanguage: AppLanguage = .automatic
    var targetLanguage: AppLanguage = .chinese
    var pairLanguageA: AppLanguage = .chinese
    var pairLanguageB: AppLanguage = .english

    func normalized() -> Self {
        var result = self
        if result.targetLanguage == .automatic { result.targetLanguage = .chinese }
        if result.pairLanguageA == .automatic { result.pairLanguageA = .chinese }
        if result.pairLanguageB == .automatic || result.pairLanguageB == result.pairLanguageA {
            result.pairLanguageB = result.pairLanguageA == .english ? .chinese : .english
        }
        return result
    }

    /// A → B, B → A; a third/unknown language uses A as the fallback target.
    /// A manually selected source always takes precedence over detection.
    func resolvedTarget(detectedSource: AppLanguage?) -> AppLanguage {
        let value = normalized()
        guard value.mode == .automaticPair else { return value.targetLanguage }
        let source = value.sourceLanguage == .automatic ? detectedSource : value.sourceLanguage
        if source == value.pairLanguageA { return value.pairLanguageB }
        if source == value.pairLanguageB { return value.pairLanguageA }
        // The default Chinese/English pair handles either Chinese script. If
        // both pair members are Chinese scripts, exact matching above decides.
        let chineseScripts: Set<AppLanguage> = [.chinese, .traditionalChinese]
        if let source, chineseScripts.contains(source) {
            if chineseScripts.contains(value.pairLanguageA) { return value.pairLanguageB }
            if chineseScripts.contains(value.pairLanguageB) { return value.pairLanguageA }
        }
        return value.pairLanguageA
    }

    static func load(from defaults: UserDefaults) -> Self {
        if let data = defaults.data(forKey: storageKey),
           let value = try? JSONDecoder().decode(Self.self, from: data) {
            return value.normalized()
        }
        // Earlier versions persisted only automaticDirection. Keep the old
        // default Chinese ↔ English pair and migrate an explicit false to a
        // fixed Chinese target; do not silently enable automatic routing again.
        let oldAutomatic = defaults.object(forKey: "automaticDirection") as? Bool ?? true
        var value = Self()
        value.mode = oldAutomatic ? .automaticPair : .fixedTarget
        return value
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(normalized()) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
