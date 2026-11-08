import XCTest
@testable import Diffactly

@MainActor
final class SearchTests: XCTestCase {

    func testSearchingForSubstringsWithScopes() {
        let document = DiffDocument(
            left: "apple banana cherry",
            right: "banana date apple"
        )

        let search = document.search

        // 1. Scope .left
        search.query = "apple"
        search.scope = .left
        search.performSearch()
        XCTAssertEqual(search.matches.count, 1)
        XCTAssertEqual(search.matches.first?.side, .left)
        XCTAssertEqual(search.matches.first?.line, 1)
        XCTAssertEqual(search.matches.first?.range, NSRange(location: 0, length: 5))

        // 2. Scope .right
        search.scope = .right
        search.performSearch()
        XCTAssertEqual(search.matches.count, 1)
        XCTAssertEqual(search.matches.first?.side, .right)
        XCTAssertEqual(search.matches.first?.line, 1)
        XCTAssertEqual(search.matches.first?.range, NSRange(location: 12, length: 5))

        // 3. Scope .both
        search.scope = .both
        search.performSearch()
        XCTAssertEqual(search.matches.count, 2)
        XCTAssertEqual(search.matches[0].side, .left)
        XCTAssertEqual(search.matches[1].side, .right)

        // 4. Searching for something on only one side
        search.query = "cherry"
        search.scope = .right
        search.performSearch()
        XCTAssertEqual(search.matches.count, 0)
        XCTAssertEqual(search.matchSummary, "No matches")

        search.scope = .both
        search.performSearch()
        XCTAssertEqual(search.matches.count, 1)
        XCTAssertEqual(search.matches.first?.side, .left)
        XCTAssertEqual(search.matchSummary, "1 of 1")
    }

    func testScopeRespectingRenamedSplitTitles() {
        let document = DiffDocument(
            left: "line 1",
            right: "line 2",
            leftTitle: "Before",
            rightTitle: "After"
        )

        XCTAssertEqual(SearchScope.both.title(in: document), "All")
        XCTAssertEqual(SearchScope.left.title(in: document), "Before")
        XCTAssertEqual(SearchScope.right.title(in: document), "After")

        // Rename titles
        document.setTitle("Original Draft", for: .left)
        document.setTitle("Final Version", for: .right)

        XCTAssertEqual(SearchScope.left.title(in: document), "Original Draft")
        XCTAssertEqual(SearchScope.right.title(in: document), "Final Version")

        // Blank title reverts to default
        document.setTitle("   ", for: .left)
        XCTAssertEqual(SearchScope.left.title(in: document), "Original")
    }

    func testCaseSensitivityAndWholeWordMatching() {
        let document = DiffDocument(
            left: "Cat caterpillar CAT cat. a_cat",
            right: ""
        )
        let search = document.search
        search.scope = .left

        // Case insensitive, not whole word: matches all 5 occurrences
        search.query = "cat"
        search.caseSensitive = false
        search.wholeWord = false
        search.performSearch()
        XCTAssertEqual(search.matches.count, 5)

        // Case sensitive, not whole word: matches "caterpillar", "cat." and "a_cat"
        search.caseSensitive = true
        search.performSearch()
        XCTAssertEqual(search.matches.count, 3)

        // Case insensitive, whole word: matches "Cat" and "CAT" and "cat." (followed by .)
        // Excludes "caterpillar" (followed by e) and "a_cat" (preceded by _)
        search.caseSensitive = false
        search.wholeWord = true
        search.performSearch()
        XCTAssertEqual(search.matches.count, 3)

        // Case sensitive, whole word: only "cat." matches
        search.caseSensitive = true
        search.wholeWord = true
        search.performSearch()
        XCTAssertEqual(search.matches.count, 1)
        XCTAssertEqual(search.matches.first?.range, NSRange(location: 20, length: 3))
    }

    func testRegexSearchAndSafelyCatchingErrors() {
        let document = DiffDocument(
            left: "user_101 user_202 admin_303",
            right: ""
        )
        let search = document.search
        search.scope = .left
        search.useRegex = true

        search.query = "user_\\d+"
        search.performSearch()
        XCTAssertEqual(search.matches.count, 2)
        XCTAssertNil(search.regexError)

        // Malformed regex should not crash
        search.query = "[invalid(regex"
        search.performSearch()
        XCTAssertEqual(search.matches.count, 0)
        XCTAssertNotNil(search.regexError)
        XCTAssertEqual(search.matchSummary, "Invalid regex")
    }

    func testCyclingNextAndPreviousWithWraparound() {
        let document = DiffDocument(
            left: "one two one three one",
            right: ""
        )
        let search = document.search
        search.scope = .left
        search.query = "one"
        search.performSearch()

        XCTAssertEqual(search.matches.count, 3)
        XCTAssertEqual(search.currentMatchIndex, 0)
        XCTAssertEqual(search.matchSummary, "1 of 3")

        // Next
        search.findNext()
        XCTAssertEqual(search.currentMatchIndex, 1)
        XCTAssertEqual(search.matchSummary, "2 of 3")

        // Next
        search.findNext()
        XCTAssertEqual(search.currentMatchIndex, 2)
        XCTAssertEqual(search.matchSummary, "3 of 3")

        // Next wraps to 0
        search.findNext()
        XCTAssertEqual(search.currentMatchIndex, 0)
        XCTAssertEqual(search.matchSummary, "1 of 3")

        // Previous wraps to 2
        search.findPrevious()
        XCTAssertEqual(search.currentMatchIndex, 2)
        XCTAssertEqual(search.matchSummary, "3 of 3")

        // Previous to 1
        search.findPrevious()
        XCTAssertEqual(search.currentMatchIndex, 1)

        // Previous to 0
        search.findPrevious()
        XCTAssertEqual(search.currentMatchIndex, 0)
    }

    func testMatchCountAndRangeAccuracy() {
        let text = "First line test\nSecond line test test\nThird line"
        let document = DiffDocument(left: text, right: "")
        let search = document.search
        search.scope = .left
        search.query = "test"
        search.performSearch()

        XCTAssertEqual(search.matches.count, 3)

        // Match 1: on line 1
        let m1 = search.matches[0]
        XCTAssertEqual(m1.line, 1)
        XCTAssertEqual(m1.range.location, 11)
        XCTAssertEqual(m1.range.length, 4)
        XCTAssertEqual(m1.lineRange.location, 11)
        XCTAssertEqual(m1.lineRange.length, 4)

        // Match 2: on line 2, first occurrence
        let m2 = search.matches[1]
        XCTAssertEqual(m2.line, 2)
        // Line 1 is "First line test\n" (16 UTF-16 units: length 15 + \n = 16)
        // Line 2 starts at offset 16. "Second line " is 12 characters. Offset 16 + 12 = 28.
        XCTAssertEqual(m2.range.location, 28)
        XCTAssertEqual(m2.range.length, 4)
        XCTAssertEqual(m2.lineRange.location, 12)
        XCTAssertEqual(m2.lineRange.length, 4)

        // Match 3: on line 2, second occurrence
        let m3 = search.matches[2]
        XCTAssertEqual(m3.line, 2)
        XCTAssertEqual(m3.range.location, 33)
        XCTAssertEqual(m3.range.length, 4)
        XCTAssertEqual(m3.lineRange.location, 17)
        XCTAssertEqual(m3.lineRange.length, 4)
    }

    func testOpenAndCloseSearchAndActiveSideScope() {
        let document = DiffDocument(left: "Left text", right: "Right text")
        XCTAssertFalse(document.search.isPresented)

        // Open when right side is active
        document.activeSide = .right
        document.openSearch()
        XCTAssertTrue(document.search.isPresented)
        XCTAssertEqual(document.search.scope, .right)

        // Close search
        document.closeSearch()
        XCTAssertFalse(document.search.isPresented)
        XCTAssertNil(document.search.currentMatchIndex)

        // Open with explicit focusedSide
        document.openSearch(focusedSide: .left)
        XCTAssertTrue(document.search.isPresented)
        XCTAssertEqual(document.search.scope, .left)
    }

    func testUseSelectionForSearch() {
        let document = DiffDocument(left: "hello world here", right: "")
        document.updateSelection(side: .left, selectedText: "world")

        document.useSelectionForSearch()

        XCTAssertTrue(document.search.isPresented)
        XCTAssertEqual(document.search.query, "world")
        XCTAssertEqual(document.search.scope, .left)
        XCTAssertEqual(document.search.matches.count, 1)
        XCTAssertEqual(document.search.currentMatchIndex, 0)
    }
}
