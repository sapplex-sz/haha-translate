import XCTest
@testable import HaHaCore

final class TextProcessingTests: XCTestCase {
    func testLongTextHasNoTruncation() {
        let text = String(repeating: "这是需要完整保留的内容。", count: 300)
        let chunks = TextProcessing.chunks(text, limit: 120)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 120 })
        XCTAssertEqual(chunks.map(\.text).joined(), text)
    }
    func testParagraphBoundariesSurvive() {
        let a = String(repeating: "A", count: 90)
        let b = String(repeating: "B", count: 90)
        let chunks = TextProcessing.chunks(a + "\n\n" + b, limit: 100)
        XCTAssertEqual(chunks.first?.text, a)
        XCTAssertEqual(chunks.first?.separator, "\n\n")
    }
    func testNumberCheckFindsLossWithoutFlaggingPreservedDecimals() {
        XCTAssertEqual(TextProcessing.missingNumbers(source: "Pay 1,200 dollars by 2026, at 3.5%.", translation: "2026 年支付 1,200 美元。"), ["3.5%"])
    }
    func testChineseAdjacentDecimalsAreCheckedInBothDirections() {
        let chinese = "重量为1.25公斤。"
        let english = "The weight is 1.25 kilograms."
        XCTAssertEqual(TextProcessing.missingNumbers(source: chinese, translation: english), [])
        XCTAssertEqual(TextProcessing.missingNumbers(source: english, translation: chinese), [])
        XCTAssertEqual(TextProcessing.missingNumbers(source: chinese, translation: "The weight is 1.5 kilograms."), ["1.25"])
        XCTAssertEqual(TextProcessing.missingNumbers(source: "The weight is 1.25kg.", translation: chinese), [])
    }
    func testBothChineseAdjacentPercentagesMustBePreserved() {
        let source = "故障率从0.8%降到0.2%。"
        XCTAssertEqual(TextProcessing.missingNumbers(source: source, translation: "The failure rate fell from 0.8% to 0.2%."), [])
        XCTAssertEqual(TextProcessing.missingNumbers(source: source, translation: "The failure rate fell to 0.2%."), ["0.8%"])
        XCTAssertEqual(TextProcessing.missingNumbers(source: source, translation: "故障率下降了。"), ["0.2%", "0.8%"])
    }
    func testNumberSignsAndPercentUnitsAreNotSilentlyLost() {
        XCTAssertEqual(TextProcessing.missingNumbers(source: "增长率为-2.5%，温度为−12度。", translation: "Growth is 2.5% and the temperature is 12 degrees."), ["-12", "-2.5%"])
        XCTAssertEqual(TextProcessing.missingNumbers(source: "增长率为−2.50％。", translation: "The growth rate is -2.5 %."), [])
        XCTAssertEqual(TextProcessing.missingNumbers(source: "故障率为百分之0.8。", translation: "The rate is 0.8 percent."), [])
        XCTAssertEqual(TextProcessing.missingNumbers(source: "故障率为0.8%。", translation: "The rate is 0.8 per\tcent."), [])
        XCTAssertEqual(TextProcessing.missingNumbers(source: "The rate is 0.8%.", translation: "比率为0.8。"), ["0.8%"])
    }
    func testLocalizedDatesAndVersionIdentifiers() {
        XCTAssertEqual(TextProcessing.missingNumbers(source: "发布日期为2026-10-03。", translation: "The release date is 2026年10月3日。"), [])
        XCTAssertEqual(TextProcessing.missingNumbers(source: "On 2026/10/03, install v1.2.3.", translation: "2026年10月3日安装版本1.2.3。"), [])
        XCTAssertEqual(TextProcessing.missingNumbers(source: "Install v1.2.3.", translation: "安装版本1.2.4。"), ["v1.2.3"])
        XCTAssertEqual(TextProcessing.missingNumbers(source: "日期2026-10-03", translation: "日期2026年10月"), ["03"])
    }
    func testASCIIIdentifiersDoNotGenerateSpuriousNumericWarnings() {
        XCTAssertEqual(TextProcessing.missingNumbers(source: "Use GPT4, GPT-4, Qwen3.5-0.8B, build_2026 and itemA123. The count is 42.", translation: "使用上述标识符，数量为42。"), [])
        XCTAssertEqual(TextProcessing.missingNumbers(source: "Use abc1.25 and X9-12; keep 3-5 samples.", translation: "保留3到5个样本。"), [])
    }
    func testEquivalentThousandsAndDecimalFormattingDoesNotWarn() {
        XCTAssertEqual(TextProcessing.missingNumbers(source: "支付1,200.00元，另加1.25元。", translation: "Pay 1200 dollars, plus 1.250."), [])
        XCTAssertEqual(TextProcessing.missingNumbers(source: "支付１２００元。", translation: "Pay 1,200."), [])
        XCTAssertEqual(TextProcessing.missingNumbers(source: "Value 1.25.", translation: "Wert 1,25."), [])
    }
    func testChunksReconstructExactTextWithoutInventingSpaces() {
        let texts = [
            String(repeating: "这是测试句子。", count: 80),
            String(repeating: "English words should stay together. ", count: 40),
            "标题\r\n\r\n" + String(repeating: "混合 👨‍👩‍👧‍👦 e\u{301} 内容\t", count: 90),
            String(repeating: "x", count: TextProcessing.maximumCharacters + 1)
        ]
        for text in texts {
            for limit in [1, 17, 120, 700] {
                let chunks = TextProcessing.chunks(text, limit: limit)
                XCTAssertEqual(chunks.map { $0.text + $0.separator }.joined(), text)
                XCTAssertTrue(chunks.allSatisfy { $0.text.count <= limit })
            }
        }
    }
    func testLongWhitespaceAndParagraphRunsDoNotCreateEmptyTranslationChunks() {
        let a = String(repeating: "A", count: 90)
        let b = String(repeating: "B", count: 90)
        let separator = String(repeating: " \t\n", count: 400)
        let chunks = TextProcessing.chunks(a + separator + b, limit: 100)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].text, a)
        XCTAssertEqual(chunks[0].separator, separator)
        XCTAssertEqual(chunks[1].text, b)
        XCTAssertTrue(chunks.allSatisfy { !$0.text.isEmpty })
    }
    func testChunkingPrefersWordBoundariesAndDoesNotTreatDecimalAsSentenceEnd() {
        let text = "One two three four five six seven eight nine ten eleven twelve"
        let chunks = TextProcessing.chunks(text, limit: 30)
        XCTAssertEqual(chunks.first?.text, "One two three four five six")
        XCTAssertEqual(chunks.first?.separator, " ")
        let decimal = "abcdefghij 1.25 kilograms of material remain"
        let decimalChunks = TextProcessing.chunks(decimal, limit: 15)
        XCTAssertEqual(decimalChunks.first?.text, "abcdefghij 1.25")
        XCTAssertEqual(decimalChunks.first?.separator, " ")
        XCTAssertEqual(decimalChunks.map { $0.text + $0.separator }.joined(), decimal)
    }
    func testLanguageDetection() {
        XCTAssertEqual(AppLanguage.detect("今天我们讨论一下本地翻译软件的设计方案。"), .chinese)
        XCTAssertEqual(AppLanguage.detect("Please send the meeting notes before Friday."), .english)
    }
}
