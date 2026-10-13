import Foundation
import NaturalLanguage

// Official Hy-MT2 language table, checked 2026-10-04:
// https://github.com/Tencent-Hunyuan/Hy-MT2#supported-languages
// Raw values retain the original app persistence names.
enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic
    case chinese
    case english
    case french
    case portuguese
    case spanish
    case japanese
    case turkish
    case russian
    case arabic
    case korean
    case thai
    case italian
    case german
    case vietnamese
    case malay
    case indonesian
    case filipino
    case hindi
    case traditionalChinese
    case polish
    case czech
    case dutch
    case khmer
    case burmese
    case persian
    case gujarati
    case urdu
    case telugu
    case marathi
    case hebrew
    case bengali
    case tamil
    case ukrainian
    case tibetan
    case kazakh
    case mongolian
    case uyghur
    case cantonese
    var id: String { rawValue }
    static var supportedLanguages: [AppLanguage] { allCases.filter { $0 != .automatic } }
    var code: String { metadata.code }
    var modelName: String { metadata.name }
    var title: String {
        self == .automatic ? L("自动识别") : localizedTitle(in: AppLocalization.shared.locale)
    }
    func localizedTitle(in locale: Locale) -> String {
        guard self != .automatic else { return L("自动识别") }
        let identifier = self == .chinese ? "zh-Hans" : code
        return locale.localizedString(forIdentifier: identifier) ?? modelName
    }
    private var metadata: (code: String, name: String) {
        switch self {
        case .automatic: return ("auto", "")
        case .chinese: return ("zh", "Chinese")
        case .english: return ("en", "English")
        case .french: return ("fr", "French")
        case .portuguese: return ("pt", "Portuguese")
        case .spanish: return ("es", "Spanish")
        case .japanese: return ("ja", "Japanese")
        case .turkish: return ("tr", "Turkish")
        case .russian: return ("ru", "Russian")
        case .arabic: return ("ar", "Arabic")
        case .korean: return ("ko", "Korean")
        case .thai: return ("th", "Thai")
        case .italian: return ("it", "Italian")
        case .german: return ("de", "German")
        case .vietnamese: return ("vi", "Vietnamese")
        case .malay: return ("ms", "Malay")
        case .indonesian: return ("id", "Indonesian")
        case .filipino: return ("tl", "Filipino")
        case .hindi: return ("hi", "Hindi")
        case .traditionalChinese: return ("zh-Hant", "Traditional Chinese")
        case .polish: return ("pl", "Polish")
        case .czech: return ("cs", "Czech")
        case .dutch: return ("nl", "Dutch")
        case .khmer: return ("km", "Khmer")
        case .burmese: return ("my", "Burmese")
        case .persian: return ("fa", "Persian")
        case .gujarati: return ("gu", "Gujarati")
        case .urdu: return ("ur", "Urdu")
        case .telugu: return ("te", "Telugu")
        case .marathi: return ("mr", "Marathi")
        case .hebrew: return ("he", "Hebrew")
        case .bengali: return ("bn", "Bengali")
        case .tamil: return ("ta", "Tamil")
        case .ukrainian: return ("uk", "Ukrainian")
        case .tibetan: return ("bo", "Tibetan")
        case .kazakh: return ("kk", "Kazakh")
        case .mongolian: return ("mn", "Mongolian")
        case .uyghur: return ("ug", "Uyghur")
        case .cantonese: return ("yue", "Cantonese")
        }
    }

    /// Maps system language identifiers; unsupported or unknown languages stay unknown.
    static func fromLanguageCode(_ identifier: String) -> AppLanguage? {
        let code = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        if code == "zh-hant" || code.hasPrefix("zh-hant-") || ["zh-tw", "zh-hk", "zh-mo"].contains(code) { return .traditionalChinese }
        if code == "zh" || code.hasPrefix("zh-hans") || code == "zh-cn" || code == "zh-sg" { return .chinese }
        let base = code.split(separator: "-").first.map(String.init) ?? code
        if base == "fil" { return .filipino }
        return supportedLanguages.first { $0.code.lowercased() == base }
    }

    static func detect(_ text: String) -> AppLanguage {
        guard text.contains(where: { $0.isLetter }),
              let language = NLLanguageRecognizer.dominantLanguage(for: text) else { return .automatic }
        return fromLanguageCode(language.rawValue) ?? .automatic
    }
}

struct TranslationChunk: Equatable {
    let text: String
    let separator: String
    var separatorAfter: String { separator }
}

enum TextProcessing {
    static let maximumCharacters = 12_000
    // Partition without dropping characters; separators are reinserted after each translated chunk.
    static func chunks(_ text: String, limit: Int = 700) -> [TranslationChunk] {
        guard limit > 0, !text.isEmpty else { return [] }
        var result: [TranslationChunk] = []
        var remaining = text[...]
        while !remaining.isEmpty {
            if remaining.count <= limit {
                result.append(.init(text: String(remaining), separator: "")); break
            }
            let end = remaining.index(remaining.startIndex, offsetBy: limit)
            let prefix = remaining[..<end]
            let half = prefix.index(prefix.startIndex, offsetBy: limit / 2)
            let tail = prefix[half...]
            let sentenceBreak = tail.indices.last { index in
                let character = remaining[index]
                if "\n。！？!?;；".contains(character) { return true }
                guard character == "." else { return false }
                let next = remaining.index(after: index)
                // A decimal point or version dot is not a sentence boundary.
                return next == remaining.endIndex || remaining[next].isWhitespace
            }
            let wordBreak = remaining[end].isWhitespace ? nil : tail.lastIndex(where: { $0.isWhitespace })
            var split = (sentenceBreak ?? wordBreak).map { remaining.index(after: $0) } ?? end
            // Keep a whole whitespace run with the preceding chunk, even when it
            // crosses the limit; separators do not consume model input capacity.
            while split < remaining.endIndex, remaining[split].isWhitespace {
                split = remaining.index(after: split)
            }
            let part = remaining[..<split]
            let trailing = part.reversed().prefix(while: { $0.isWhitespace }).reversed()
            let separator = String(trailing)
            let content = String(part.dropLast(separator.count))
            result.append(.init(text: content, separator: separator))
            remaining = remaining[split...]
        }
        return result
    }

    static func missingNumbers(source: String, translation: String) -> [String] {
        let original = numericTokens(source)
        let translated = Set(numericTokens(translation).map(\.key))
        var missing: [String: String] = [:]
        for token in original where !translated.contains(token.key) {
            if missing[token.key] == nil { missing[token.key] = token.display }
        }
        return missing.values.sorted()
    }

    private struct NumericToken {
        let key: String
        let display: String
    }

    private static func numericTokens(_ input: String) -> [NumericToken] {
        // Only ASCII identifier letters are excluded at the left boundary: Chinese,
        // Japanese and Korean normally put words directly beside meaningful numbers.
        let pattern = #"(?<![A-Za-z0-9_.])(?:[vV][0-9]+(?:\.[0-9]+)+|[0-9]{4}[-/.][0-9]{1,2}[-/.][0-9]{1,2}|[+\-]?[0-9]+(?:[.,][0-9]+)*(?:[ \t]*(?:%|percent\b|per[ \t]+cent\b))?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let value = (input.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? input)
            .replacingOccurrences(of: "−", with: "-")
        let ns = value as NSString
        let units: Set<String> = ["kg", "g", "mg", "km", "m", "cm", "mm", "s", "ms", "h", "hz", "khz", "mhz", "ghz", "kb", "mb", "gb", "tb", "kib", "mib", "gib", "px", "pt"]
        func asciiLetter(_ character: Character) -> Bool {
            character.isASCII && (character.isLetter || character == "_")
        }
        return regex.matches(in: value, range: NSRange(location: 0, length: ns.length)).flatMap { match -> [NumericToken] in
            guard let range = Range(match.range, in: value) else { return [] }
            let raw = String(value[range])
            // Avoid extracting the numeric tail of identifiers such as GPT-4 or
            // Qwen3.5-0.8B, while allowing natural no-space units such as 1.25kg.
            if range.lowerBound > value.startIndex {
                let before = value.index(before: range.lowerBound)
                if value[before] == "-", before > value.startIndex {
                    let prefix = value[..<before].reversed().prefix {
                        $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0))
                    }
                    if prefix.contains(where: asciiLetter) { return [] }
                }
            }
            if range.upperBound < value.endIndex, asciiLetter(value[range.upperBound]) {
                let suffix = String(value[range.upperBound...].prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
                if !units.contains(suffix.lowercased()) { return [] }
            }
            if raw.range(of: #"^[0-9]{4}[-/.][0-9]{1,2}[-/.][0-9]{1,2}$"#, options: .regularExpression) != nil {
                // Match localized dates component-wise (2026-10-03 ↔ 2026年10月3日).
                return raw.split(whereSeparator: { "-/.".contains($0) }).map {
                    NumericToken(key: canonicalNumber(String($0)), display: String($0))
                }
            }
            let hasPercentPrefix = value[..<range.lowerBound].hasSuffix("百分之")
            return [NumericToken(key: canonicalNumber(raw) + (hasPercentPrefix ? "%" : ""), display: raw)]
        }
    }

    private static func canonicalNumber(_ input: String) -> String {
        var value = input.lowercased().filter { !$0.isWhitespace }
            .replacingOccurrences(of: "percent", with: "%")
        if value.first == "v" { value.removeFirst() }
        let percent = value.hasSuffix("%")
        if percent { value.removeLast() }
        let negative = value.first == "-"
        if value.first == "+" || negative { value.removeFirst() }
        // Preserve multi-dot version identifiers as a unit instead of comparing
        // only their tail. Do not round large identifiers through floating point.
        if value.filter({ $0 == "." }).count > 1 { return value + (percent ? "%" : "") }
        if value.range(of: #"^[0-9]{1,3}(?:,[0-9]{3})+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil {
            value.removeAll(where: { $0 == "," })
        } else if value.filter({ $0 == "," }).count == 1, !value.contains(".") {
            value = value.replacingOccurrences(of: ",", with: ".")
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let integer = String(parts[0].drop(while: { $0 == "0" }))
        let fraction = parts.count == 2 ? String(parts[1].reversed().drop(while: { $0 == "0" }).reversed()) : ""
        let magnitude = (integer.isEmpty ? "0" : integer) + (fraction.isEmpty ? "" : "." + fraction)
        return (negative && magnitude != "0" ? "-" : "") + magnitude + (percent ? "%" : "")
    }
}

struct GlossaryEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var source: String
    var target: String
}

struct HistoryEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var date = Date()
    var source: String
    var translation: String
    var language: String
    var languageCode: String? = nil
    var resolvedLanguage: AppLanguage? {
        if let languageCode, let known = AppLanguage(rawValue: languageCode), known != .automatic { return known }
        if let known = AppLanguage.supportedLanguages.first(where: { $0.modelName == language || $0.rawValue == language }) { return known }
        // Old history stored a localized display label instead of a stable ID.
        let legacy: [String: AppLanguage] = ["简体中文": .chinese, "英语": .english,
            "日语": .japanese, "韩语": .korean, "法语": .french, "德语": .german,
            "西班牙语": .spanish, "俄语": .russian]
        return legacy[language]
    }
    var languageTitle: String { resolvedLanguage?.title ?? language }
}
