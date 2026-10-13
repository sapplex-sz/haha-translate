import XCTest
@testable import HaHaCore

final class LocalizationTests: XCTestCase {
    func testSystemResolutionUsesSupportedLanguageAndEnglishFallback() {
        XCTAssertEqual(AppLocalization.resolvedIdentifier(selection: "system", preferred: ["de-DE"]), "de")
        XCTAssertEqual(AppLocalization.resolvedIdentifier(selection: "system", preferred: ["pt-BR"]), "pt")
        XCTAssertEqual(AppLocalization.resolvedIdentifier(selection: "system", preferred: ["zh-HK"]), "zh-Hant")
        XCTAssertEqual(AppLocalization.resolvedIdentifier(selection: "system", preferred: ["zh-CN"]), "zh-Hans")
        XCTAssertEqual(AppLocalization.resolvedIdentifier(selection: "system", preferred: ["nl-NL"]), "en")
        XCTAssertEqual(AppLocalization.resolvedIdentifier(selection: "en", preferred: ["zh-Hans"]), "en")
    }

    func testLanguageSelectionPersistsAndLoadsActualResourceStrings() {
        let suite = "HaHaLocalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let localization = AppLocalization(defaults: defaults, preferredLanguages: { ["en-US"] })
        XCTAssertEqual(localization.language, "system")
        XCTAssertEqual(localization.string("复制"), "Copy")
        XCTAssertEqual(localization.string("%@已就绪。", arguments: ["Model"]), "Model is ready.")
        localization.language = "zh-Hans"
        XCTAssertEqual(localization.string("复制"), "复制")
        let relaunched = AppLocalization(defaults: defaults, preferredLanguages: { ["en-US"] })
        XCTAssertEqual(relaunched.language, "zh-Hans")
        XCTAssertEqual(relaunched.locale.identifier, "zh-Hans")
        XCTAssertEqual(relaunched.string("复制"), "复制")
    }

    func testEverySupportedLanguageLoadsItsOwnCatalog() {
        let suite = "HaHaLocalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let localization = AppLocalization(defaults: defaults, preferredLanguages: { ["en-US"] })
        let expected = ["en": "Copy", "zh-Hans": "复制", "zh-Hant": "複製", "ja": "コピー", "ko": "복사",
                        "fr": "Copier", "de": "Kopieren", "es": "Copiar", "pt": "Copiar", "ru": "Копировать", "it": "Copia"]
        for language in AppLocalization.supportedLanguages where language.id != "system" {
            localization.language = language.id
            XCTAssertEqual(localization.string("复制"), expected[language.id], language.id)
        }
        // A translated value may legitimately equal its Chinese lookup key.
        // It must not be mistaken for a missing resource and fall back to English.
        localization.language = "zh-Hant"
        XCTAssertEqual(localization.string("取消"), "取消")
    }

}
