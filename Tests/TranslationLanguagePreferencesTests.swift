import XCTest
@testable import HaHaCore

final class TranslationLanguagePreferencesTests: XCTestCase {
    private func isolatedDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "HaHaLanguageTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    func testOfficialLanguageCatalogIncludesAllThirtyEightTargets() {
        // Tencent's Hy-MT2 README supported-languages table, checked 2026-10-04.
        let officialCodes = Set("zh en fr pt es ja tr ru ar ko th it de vi ms id tl hi zh-Hant pl cs nl km my fa gu ur te mr he bn ta uk bo kk mn ug yue".split(separator: " ").map(String.init))
        XCTAssertEqual(Set(AppLanguage.supportedLanguages.map(\.code)), officialCodes)
        XCTAssertEqual(AppLanguage.supportedLanguages.count, 38)
        XCTAssertEqual(AppLanguage.allCases.count, 39)
        XCTAssertEqual(Set(AppLanguage.supportedLanguages.map(\.modelName)).count, 38)
        XCTAssertFalse(AppLanguage.supportedLanguages.contains(.automatic))
        XCTAssertEqual(AppLanguage.traditionalChinese.modelName, "Traditional Chinese")
        XCTAssertEqual(AppLanguage.filipino.modelName, "Filipino")
        XCTAssertEqual(AppLanguage.uyghur.modelName, "Uyghur")
    }

    func testLanguageDisplayNamesFollowRequestedLocaleWithoutChangingPromptNames() {
        XCTAssertEqual(AppLanguage.english.localizedTitle(in: Locale(identifier: "en")), "English")
        XCTAssertEqual(AppLanguage.english.localizedTitle(in: Locale(identifier: "ja")), "英語")
        XCTAssertEqual(AppLanguage.german.modelName, "German")
        XCTAssertNotEqual(AppLanguage.german.localizedTitle(in: Locale(identifier: "zh-Hans")), AppLanguage.german.modelName)
    }

    func testSystemLanguageIdentifiersMapToSupportedLanguages() {
        XCTAssertEqual(AppLanguage.fromLanguageCode("zh-Hans-CN"), .chinese)
        XCTAssertEqual(AppLanguage.fromLanguageCode("zh_Hant_TW"), .traditionalChinese)
        XCTAssertEqual(AppLanguage.fromLanguageCode("zh-TW"), .traditionalChinese)
        XCTAssertEqual(AppLanguage.fromLanguageCode("fil-PH"), .filipino)
        XCTAssertEqual(AppLanguage.fromLanguageCode("tl"), .filipino)
        XCTAssertEqual(AppLanguage.fromLanguageCode("yue-Hant-HK"), .cantonese)
        XCTAssertEqual(AppLanguage.fromLanguageCode("pt-BR"), .portuguese)
        XCTAssertNil(AppLanguage.fromLanguageCode("xx"))
        XCTAssertEqual(AppLanguage.detect("1234, 56%!"), .automatic)
        XCTAssertEqual(AppLanguage.detect(""), .automatic)
    }

    func testDefaultChineseEnglishPairAndOtherSourceFallback() {
        let value = TranslationLanguagePreferences()
        XCTAssertEqual(value.sourceLanguage, .automatic)
        XCTAssertEqual(value.resolvedTarget(detectedSource: .chinese), .english)
        XCTAssertEqual(value.resolvedTarget(detectedSource: .english), .chinese)
        XCTAssertEqual(value.resolvedTarget(detectedSource: .traditionalChinese), .english)
        XCTAssertEqual(value.resolvedTarget(detectedSource: .japanese), .chinese)
        XCTAssertEqual(value.resolvedTarget(detectedSource: nil), .chinese)
        XCTAssertEqual(value.resolvedTarget(detectedSource: .automatic), .chinese)
    }

    func testCustomPairRoutesBothDirectionsAndUnknownToFirstMember() {
        let value = TranslationLanguagePreferences(pairLanguageA: .japanese, pairLanguageB: .french)
        XCTAssertEqual(value.resolvedTarget(detectedSource: .japanese), .french)
        XCTAssertEqual(value.resolvedTarget(detectedSource: .french), .japanese)
        XCTAssertEqual(value.resolvedTarget(detectedSource: .english), .japanese)
        XCTAssertEqual(value.resolvedTarget(detectedSource: nil), .japanese)
    }

    func testManualSourceOverridesAutomaticDetection() {
        let value = TranslationLanguagePreferences(sourceLanguage: .english)
        XCTAssertEqual(value.resolvedTarget(detectedSource: .chinese), .chinese)
        XCTAssertEqual(value.resolvedTarget(detectedSource: nil), .chinese)
    }

    func testFixedTargetSupportsAllSourcesAndDoesNotSwitchOnMatchingTarget() {
        let value = TranslationLanguagePreferences(mode: .fixedTarget, targetLanguage: .portuguese)
        for language in AppLanguage.allCases {
            XCTAssertEqual(value.resolvedTarget(detectedSource: language), .portuguese)
        }
        XCTAssertEqual(value.resolvedTarget(detectedSource: nil), .portuguese)
    }

    func testChineseScriptPairCanConvertInBothDirections() {
        let value = TranslationLanguagePreferences(pairLanguageA: .chinese, pairLanguageB: .traditionalChinese)
        XCTAssertEqual(value.resolvedTarget(detectedSource: .chinese), .traditionalChinese)
        XCTAssertEqual(value.resolvedTarget(detectedSource: .traditionalChinese), .chinese)
    }

    func testInvalidAutomaticTargetsAndDuplicatePairsNormalizeSafely() {
        let invalid = TranslationLanguagePreferences(targetLanguage: .automatic, pairLanguageA: .automatic, pairLanguageB: .automatic).normalized()
        XCTAssertEqual(invalid.targetLanguage, .chinese)
        XCTAssertEqual(invalid.pairLanguageA, .chinese)
        XCTAssertEqual(invalid.pairLanguageB, .english)
        let duplicate = TranslationLanguagePreferences(pairLanguageA: .english, pairLanguageB: .english).normalized()
        XCTAssertEqual(duplicate.pairLanguageA, .english)
        XCTAssertEqual(duplicate.pairLanguageB, .chinese)
    }

    func testFreshInstallKeepsAutomaticChineseEnglishDefaults() {
        isolatedDefaults { defaults in
            XCTAssertEqual(TranslationLanguagePreferences.load(from: defaults), TranslationLanguagePreferences())
        }
    }

    func testLegacyAutomaticDirectionMigration() {
        isolatedDefaults { defaults in
            defaults.set(false, forKey: "automaticDirection")
            let migrated = TranslationLanguagePreferences.load(from: defaults)
            XCTAssertEqual(migrated.mode, .fixedTarget)
            XCTAssertEqual(migrated.sourceLanguage, .automatic)
            XCTAssertEqual(migrated.targetLanguage, .chinese)
            migrated.save(to: defaults)
            defaults.set(true, forKey: "automaticDirection")
            XCTAssertEqual(TranslationLanguagePreferences.load(from: defaults), migrated)
        }
    }

    func testAllLanguagePreferencesRoundTripThroughStoredJSON() throws {
        try isolatedDefaults { defaults in
            let value = TranslationLanguagePreferences(mode: .fixedTarget, sourceLanguage: .arabic,
                targetLanguage: .spanish, pairLanguageA: .korean, pairLanguageB: .german)
            value.save(to: defaults)
            XCTAssertEqual(TranslationLanguagePreferences.load(from: defaults), value)
            let data = defaults.data(forKey: TranslationLanguagePreferences.storageKey)!
            XCTAssertEqual(try JSONDecoder().decode(TranslationLanguagePreferences.self, from: data), value)
        }
    }

    func testCorruptPreferencesFallbackToLegacyChoiceWithoutInvalidTargets() {
        isolatedDefaults { defaults in
            defaults.set(false, forKey: "automaticDirection")
            defaults.set(Data("{broken}".utf8), forKey: TranslationLanguagePreferences.storageKey)
            let value = TranslationLanguagePreferences.load(from: defaults)
            XCTAssertEqual(value.mode, .fixedTarget)
            XCTAssertEqual(value.targetLanguage, .chinese)
        }
    }

    func testLegacyHistoryWithoutLanguageCodeRemainsDecodable() throws {
        let old = HistoryEntry(source: "你好", translation: "Hello", language: "英语")
        let data = try JSONEncoder().encode(old)
        let restored = try JSONDecoder().decode(HistoryEntry.self, from: data)
        XCTAssertNil(restored.languageCode)
        XCTAssertEqual(restored.resolvedLanguage, .english)
        XCTAssertEqual(restored.translation, "Hello")
        let current = HistoryEntry(source: "你好", translation: "Bonjour", language: "French", languageCode: AppLanguage.french.rawValue)
        XCTAssertEqual(try JSONDecoder().decode(HistoryEntry.self, from: JSONEncoder().encode(current)).resolvedLanguage, .french)
    }
}
