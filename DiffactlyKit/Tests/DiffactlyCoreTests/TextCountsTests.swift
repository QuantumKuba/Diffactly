import XCTest
@testable import DiffactlyCore

final class TextCountsTests: XCTestCase {

    func testEmptyAndWhitespaceOnly() {
        XCTAssertEqual(TextCounts(""), .zero)
        XCTAssertEqual(TextCounts("   \t "), TextCounts(words: 0, characters: 5, lines: 1))
        XCTAssertEqual(TextCounts("\n"), TextCounts(words: 0, characters: 1, lines: 1))
    }

    func testWordsAreWhitespaceSeparatedRuns() {
        XCTAssertEqual(TextCounts("hello world").words, 2)
        XCTAssertEqual(TextCounts("  hello \t  world\n\n again ").words, 3)
        XCTAssertEqual(TextCounts("don't stop-gap 3.14 a/b").words, 4)
        // No-break space and other Unicode spaces separate words too.
        XCTAssertEqual(TextCounts("one\u{00A0}two\u{2003}three").words, 3)
    }

    func testCharactersCountGraphemeClusters() {
        XCTAssertEqual(TextCounts("héllo 👋🏽").characters, 7)
        XCTAssertEqual(TextCounts("a\r\nb").characters, 3)
    }

    func testLinesIgnoreOneTrailingLineBreak() {
        XCTAssertEqual(TextCounts("a").lines, 1)
        XCTAssertEqual(TextCounts("a\n").lines, 1)
        XCTAssertEqual(TextCounts("a\nb").lines, 2)
        XCTAssertEqual(TextCounts("a\nb\n").lines, 2)
        XCTAssertEqual(TextCounts("a\n\nb").lines, 3)
    }

    func testCRLFLinesAreCounted() {
        XCTAssertEqual(TextCounts("a\r\nb\r\n").lines, 2)
        XCTAssertEqual(TextCounts("a\r\nb").lines, 2)
    }

    func testLinesMatchTheDiffEngine() {
        for text in ["", "a", "a\n", "a\nb", "a\r\nb\r\n", "\n", "x\n\ny\n"] {
            XCTAssertEqual(TextCounts(text).lines, DiffEngine.compare(text, "").stats.leftLineCount, "lines of \(text.debugDescription)")
        }
    }
}
