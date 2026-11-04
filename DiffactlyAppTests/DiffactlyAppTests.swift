import XCTest
import SwiftUI
import DiffactlyCore
@testable import Diffactly

/// App-level behaviour on top of the DiffactlyCore engine (the engine itself is
/// tested in DiffactlyKit/Tests).
@MainActor
final class DiffDocumentTests: XCTestCase {

    private func waitForDiff(_ document: DiffDocument, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<100 {
            if !document.isComputing { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("diff did not finish", file: file, line: line)
    }

    func testHighlightsUseUTF16RangesThatMatchTheEditor() {
        let left = "héllo 👋 world\nsecond line\n"
        let right = "héllo 👋 there\nsecond line\n"
        let result = DiffEngine.compare(left, right, options: DiffOptions(level: .word))
        let leftMarks = EditorHighlights(result: result, side: .left, text: left)
        let rightMarks = EditorHighlights(result: result, side: .right, text: right)
        XCTAssertEqual(leftMarks.lines.map(\.line), [1])
        XCTAssertEqual(leftMarks.words.map { (left as NSString).substring(with: $0.range) }, ["world"])
        XCTAssertEqual(rightMarks.words.map { (right as NSString).substring(with: $0.range) }, ["there"])
        XCTAssertEqual((left as NSString).substring(with: leftMarks.lines[0].range), "héllo 👋 world")
    }

    func testAddedAndRemovedLinesAreMarkedOnTheirSide() {
        let left = "keep\ngone\nkeep too\n"
        let right = "keep\nkeep too\nfresh\n"
        let result = DiffEngine.compare(left, right)
        let l = EditorHighlights(result: result, side: .left, text: left)
        let r = EditorHighlights(result: result, side: .right, text: right)
        XCTAssertEqual(l.lines.map(\.line), [2])
        XCTAssertEqual(l.lines.first?.style, .removed)
        XCTAssertEqual(r.lines.map(\.line), [3])
        XCTAssertEqual(r.lines.first?.style, .added)
    }

    func testDocumentComputesSwapsAndTransforms() async {
        let document = DiffDocument(left: "b\na\n", right: "a\nb\n")
        await waitForDiff(document)
        XCTAssertFalse(document.result.isIdentical)

        document.apply(.sortLines)
        await waitForDiff(document)
        XCTAssertEqual(document.leftText, "a\nb\n")
        XCTAssertTrue(document.result.isIdentical)

        document.leftText = "one"
        document.rightText = "two"
        document.swapSides()
        XCTAssertEqual(document.leftText, "two")
        XCTAssertEqual(document.rightText, "one")
    }

    func testNavigationCyclesThroughChanges() async {
        let document = DiffDocument(left: "a\nx\nb\nc\nd\ne\nf\ny\n", right: "a\nX\nb\nc\nd\ne\nf\nY\n")
        await waitForDiff(document)
        XCTAssertEqual(document.result.hunks.count, 2)
        document.nextChange()
        XCTAssertEqual(document.currentHunk, 0)
        XCTAssertEqual(document.focusRequest?.leftLines, 2...2)
        document.nextChange()
        XCTAssertEqual(document.currentHunk, 1)
        document.nextChange()
        XCTAssertEqual(document.currentHunk, 0, "wraps around")
        document.previousChange()
        XCTAssertEqual(document.currentHunk, 1)
    }

    func testUnifiedPatchUsesFileNames() async {
        let document = DiffDocument(left: "a\n", right: "b\n")
        document.leftName = "old.txt"
        document.rightName = "new.txt"
        await waitForDiff(document)
        XCTAssertTrue(document.unifiedPatch.hasPrefix("--- a/old.txt\n+++ b/new.txt\n"))
    }

    func testOutputModelZipsAndFolds() {
        let left = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let right = left.replacingOccurrences(of: "line 10", with: "line ten")
        let result = DiffEngine.compare(left, right)
        let folded = OutputModel(result: result, layout: .split, collapse: true, expanded: [], context: 3)
        // 3 context + change + 3 context, with folds before and after.
        XCTAssertEqual(folded.items.count, 9)
        let full = OutputModel(result: result, layout: .split, collapse: false, expanded: [], context: 3)
        XCTAssertEqual(full.items.count, 20)
        XCTAssertNotNil(folded.itemID(forRow: result.hunks[0].rowRange.lowerBound))
    }
}
