import Combine
import Foundation

struct InterfaceLanguage: Identifiable, Sendable {
    let id: String
    let name: String
}

/// App language is independent of the source/target languages used for translation.
/// Callers change `language` on the UI thread; lookups use a locked immutable snapshot.
final class AppLocalization: ObservableObject, @unchecked Sendable {
    static let shared = AppLocalization()
    static let preferenceKey = "HaHaTranslate.interfaceLanguage"
    static let supportedLanguages: [InterfaceLanguage] = [
        .init(id: "system", name: "System"),
        .init(id: "en", name: "English"),
        .init(id: "zh-Hans", name: "简体中文"),
        .init(id: "zh-Hant", name: "繁體中文"),
        .init(id: "ja", name: "日本語"),
        .init(id: "ko", name: "한국어"),
        .init(id: "fr", name: "Français"),
        .init(id: "de", name: "Deutsch"),
        .init(id: "es", name: "Español"),
        .init(id: "pt", name: "Português"),
        .init(id: "ru", name: "Русский"),
        .init(id: "it", name: "Italiano")
    ]

    @Published var language: String {
        didSet {
            defaults.set(language, forKey: Self.preferenceKey)
            refreshSnapshot()
        }
    }
    private let defaults: UserDefaults
    private let resourceBundle: Bundle
    private let preferredLanguages: () -> [String]
    private let lock = NSLock()
    private var snapshot: (identifier: String, bundle: Bundle?) = ("en", nil)
    private var englishBundle: Bundle?

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main,
         preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages }) {
        self.defaults = defaults
        self.resourceBundle = bundle
        self.preferredLanguages = preferredLanguages
        let saved = defaults.string(forKey: Self.preferenceKey) ?? "system"
        language = Self.supportedLanguages.contains(where: { $0.id == saved }) ? saved : "system"
        englishBundle = localizedBundle("en")
        refreshSnapshot()
    }

    var resolvedLanguage: String { lock.lock(); defer { lock.unlock() }; return snapshot.identifier }
    var locale: Locale { Locale(identifier: resolvedLanguage) }

    static func resolvedIdentifier(selection: String, preferred: [String]) -> String {
        let available = Set(supportedLanguages.map(\.id)).subtracting(["system"])
        if selection != "system", available.contains(selection) { return selection }
        for raw in preferred {
            let code = raw.replacingOccurrences(of: "_", with: "-")
            if code == "zh" || code.hasPrefix("zh-") {
                if code.contains("Hant") || code.contains("TW") || code.contains("HK") || code.contains("MO") { return "zh-Hant" }
                return "zh-Hans"
            }
            let base = String(code.split(separator: "-").first ?? "")
            if available.contains(base) { return base }
        }
        return "en"
    }

    func string(_ key: String, arguments: [CVarArg] = []) -> String {
        lock.lock(); let current = snapshot; let fallback = englishBundle; lock.unlock()
        let missing = "__HaHaMissingLocalization__"
        let format = current.bundle?.localizedString(forKey: key, value: missing, table: nil) ?? missing
        let value = format == missing
            ? (fallback?.localizedString(forKey: key, value: key, table: nil) ?? key) : format
        return arguments.isEmpty ? value : String(format: value, locale: Locale(identifier: current.identifier), arguments: arguments)
    }

    private func refreshSnapshot() {
        let identifier = Self.resolvedIdentifier(selection: language, preferred: preferredLanguages())
        let bundle = localizedBundle(identifier)
        lock.lock(); snapshot = (identifier, bundle); lock.unlock()
    }

    private func localizedBundle(_ identifier: String) -> Bundle? {
        if let path = resourceBundle.path(forResource: identifier, ofType: "lproj") { return Bundle(path: path) }
        #if SWIFT_PACKAGE
        // Core tests run independently of the Xcode application resource phase.
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/\(identifier).lproj")
        return Bundle(url: folder)
        #else
        return nil
        #endif
    }
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    AppLocalization.shared.string(key, arguments: arguments)
}
