import XCTest
@testable import DiffactlyCore

final class PassageAlignmentTests: XCTestCase {

    private func map(_ selection: String, in old: String, to new: String) -> String? {
        let range = (old as NSString).range(of: selection)
        XCTAssertNotEqual(range.location, NSNotFound)
        return PassageAlignment.map(range, from: old, to: new).map { (new as NSString).substring(with: $0) }
    }

    func testSentencesFollowTheirRewrite() {
        let old = "The study was pivotal. It showed a clear effect. Results were robust across all groups."
        let new = "The study mattered. It showed a strong effect in practice. Results held across every group."
        XCTAssertEqual(map("It showed a clear effect.", in: old, to: new), "It showed a strong effect in practice.")
        XCTAssertEqual(map("The study was pivotal. It showed a clear effect.", in: old, to: new),
                       "The study mattered. It showed a strong effect in practice.")
        XCTAssertEqual(map("Results were robust across all groups.", in: old, to: new), "Results held across every group.")
    }

    func testAChangedEdgeTakesTheWholeChange() {
        let old = "We saw a pivotal shift in the data."
        let new = "We saw a big shift in the data."
        XCTAssertEqual(map("pivotal shift", in: old, to: new), "big shift")
        XCTAssertEqual(map("in the data", in: old, to: new), "in the data")
    }

    func testPartOfAWordWidensToTheWord() {
        let old = "Alpha beta gamma."
        let new = "Alpha betamax gamma."
        XCTAssertEqual(map("bet", in: old, to: new), "betamax")
    }

    func testCompletelyRewrittenTextMapsToAll() {
        let old = "One two three."
        let new = "Four five six."
        XCTAssertEqual(map("two", in: old, to: new), "Four five six", "the shared full stop stays out")
    }

    func testEmptyOrOutOfRangeSelectionsGiveNothing() {
        XCTAssertNil(PassageAlignment.map(NSRange(location: 0, length: 0), from: "a b", to: "a b"))
        XCTAssertNil(PassageAlignment.map(NSRange(location: 2, length: 9), from: "a b", to: "a b"))
        XCTAssertNil(PassageAlignment.map(NSRange(location: 0, length: 1), from: "a", to: ""))
    }

    func testTrimmedDropsSurroundingWhitespace() {
        let ns = "  word \n" as NSString
        XCTAssertEqual(PassageAlignment.trimmed(NSRange(location: 0, length: ns.length), in: ns), NSRange(location: 2, length: 4))
    }
}
