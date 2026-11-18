import XCTest
@testable import DiffactlyCore

final class PassageMatchTests: XCTestCase {

    private func match(_ left: String, _ right: String, select passage: String, onLeft: Bool) -> PassageMatch.Match? {
        let text = onLeft ? left : right
        let other = onLeft ? right : left
        let result = DiffEngine.compare(left, right)
        let range = (text as NSString).range(of: passage)
        return PassageMatch.counterpart(in: result, fromLeft: onLeft, range: range, text: text, otherText: other)
    }

    // MARK: Highlighted counterparts

    func testMarkedRangesBecomeTheCounterpartInReadingOrder() {
        let other = "One.\nTwo is here.\nThree.\nFour is here."
        let ns = other as NSString
        let m = try! XCTUnwrap(PassageMatch.marked([ns.range(of: "Four is here."), ns.range(of: "Two is here.")], in: other))
        XCTAssertEqual(m.text, "Two is here.\n[…]\nFour is here.")
        XCTAssertEqual(m.lines, [2, 4])
        XCTAssertTrue(m.isMarked)
        XCTAssertFalse(m.isIdentical)
    }

    func testMarkedTextEqualToThePassageIsIdentical() {
        let other = "Same words here."
        let m = try! XCTUnwrap(PassageMatch.marked([NSRange(location: 0, length: 16)], in: other, passage: " Same words here.\n"))
        XCTAssertTrue(m.isIdentical)
    }

    func testBlankOrOutOfBoundsMarksGiveNoCounterpart() {
        XCTAssertNil(PassageMatch.marked([NSRange(location: 0, length: 3)], in: "   x"))
        XCTAssertNil(PassageMatch.marked([NSRange(location: 2, length: 50)], in: "short"))
        XCTAssertNil(PassageMatch.marked([], in: "text"))
    }

    // MARK: Counterparts

    func testModifiedParagraphMatchesItsEditedVersion() {
        let left = "Intro stays.\nThe old results were good.\nOutro stays."
        let right = "Intro stays.\nThe new results were excellent.\nOutro stays."
        let m = try! XCTUnwrap(match(left, right, select: "results were excellent", onLeft: false))
        XCTAssertEqual(m.text, "The old results were good.")
        XCTAssertEqual(m.lines, [2])
        XCTAssertFalse(m.isIdentical)
    }

    func testUnchangedLinesAreReportedAsIdentical() {
        let left = "Same first line.\nChanged here.\nSame last line."
        let right = "Same first line.\nChanged there.\nSame last line."
        let m = try! XCTUnwrap(match(left, right, select: "Same first", onLeft: true))
        XCTAssertEqual(m.text, "Same first line.")
        XCTAssertTrue(m.isIdentical)
    }

    func testRemovedLinesMatchWhatTheOtherSideHasInTheirPlace() {
        let left = "Keep.\nAlpha beta gamma delta.\nEpsilon zeta eta theta.\nKeep too."
        let right = "Keep.\nSomething entirely different here.\nKeep too."
        let m = try! XCTUnwrap(match(left, right, select: "Alpha beta", onLeft: true))
        XCTAssertTrue(m.text.contains("Something entirely different here."), m.text)
        XCTAssertFalse(m.isIdentical)
    }

    func testPureAdditionHasNoCounterpart() {
        let left = "One.\nTwo."
        let right = "One.\nA brand new paragraph.\nTwo."
        XCTAssertNil(match(left, right, select: "brand new", onLeft: false))
    }

    func testMultiLineSelectionCollectsEveryMatchingLine() {
        let left = "A one.\nB two.\nC three."
        let right = "A one!\nB two!\nC three."
        let m = try! XCTUnwrap(match(left, right, select: "one!\nB two", onLeft: false))
        XCTAssertEqual(m.lines, [1, 2])
        XCTAssertEqual(m.text, "A one.\nB two.")
    }

    func testLineNumbers() {
        let ns = "a\nbb\n\nccc" as NSString
        XCTAssertEqual(PassageMatch.lineNumber(at: 0, in: ns), 1)
        XCTAssertEqual(PassageMatch.lineNumber(at: 1, in: ns), 1)   // the newline ends line 1
        XCTAssertEqual(PassageMatch.lineNumber(at: 2, in: ns), 2)
        XCTAssertEqual(PassageMatch.lineNumber(at: 5, in: ns), 3)
        XCTAssertEqual(PassageMatch.lineNumber(at: 6, in: ns), 4)
    }

    // MARK: Following a passage through edits

    private func follow(_ passage: String, from old: String, to new: String) -> TrackedRange.Outcome {
        TrackedRange.follow((old as NSString).range(of: passage), passage: passage, old: old, new: new)
    }

    private func intact(_ passage: String, in text: String) -> TrackedRange.Outcome {
        .intact((text as NSString).range(of: passage))
    }

    func testEditsBeforeAndAfterMoveOrKeepTheRange() {
        XCTAssertEqual(follow("target", from: "One target two", to: "Zero. One target two"), intact("target", in: "Zero. One target two"))
        XCTAssertEqual(follow("target", from: "One target two", to: "One target two three"), .intact(NSRange(location: 4, length: 6)))
        XCTAssertEqual(follow("target", from: "Long intro. target", to: "target"), .intact(NSRange(location: 0, length: 6)))
    }

    func testTypingNextToThePassageDoesNotBreakIt() {
        // "t" typed just before "target": the minimal diff lands inside the passage.
        XCTAssertEqual(follow("target", from: "a target", to: "a ttarget"), .intact(NSRange(location: 3, length: 6)))
        XCTAssertEqual(follow("target", from: "a target b", to: "a targett b"), .intact(NSRange(location: 2, length: 6)))
    }

    func testEditingInsideThePassageMarksItEdited() {
        guard case .edited(let range) = follow("the target text", from: "Before the target text after", to: "Before the goal text after") else {
            return XCTFail("expected an edited passage")
        }
        XCTAssertEqual(("Before the goal text after" as NSString).substring(with: range), "the goal text")
    }

    func testClearingTheTextRemovesThePassage() {
        XCTAssertEqual(follow("target", from: "a target", to: ""), .removed)
    }

    func testChangedRangesMatchTheEditorsMinimalEdit() {
        let r = TrackedRange.changedRanges(old: "Hello brave world", new: "Hello new world")
        XCTAssertEqual(r.old, NSRange(location: 6, length: 5))
        XCTAssertEqual(r.new, NSRange(location: 6, length: 3))
    }

    func testOneMeasuredEditServesSeveralRanges() {
        let old = "One alpha two beta three", new = "Zero. One alpha two beta three"
        let change = TrackedRange.changedRanges(old: old, new: new)
        for passage in ["alpha", "beta"] {
            XCTAssertEqual(TrackedRange.follow((old as NSString).range(of: passage), passage: passage, change: change, new: new),
                           intact(passage, in: new))
        }
    }

    func testShiftingAPosition() {
        let change = TrackedRange.changedRanges(old: "abcdef", new: "abXXcdef")   // 2 inserted at 2
        XCTAssertEqual(TrackedRange.shift(1, change: change), 1, "before the edit")
        XCTAssertEqual(TrackedRange.shift(4, change: change), 6, "after it")
        let deletion = TrackedRange.changedRanges(old: "abcdef", new: "af")      // "bcde" deleted
        XCTAssertEqual(TrackedRange.shift(3, change: deletion), 1, "inside a deletion: its start")
        XCTAssertEqual(TrackedRange.shift(6, change: deletion), 2)
    }

    // MARK: Blending in the prompt

    private func spec(weight: Double, counterpart: String? = "Old wording of the claim.") -> SelectionRewriteSpec {
        let doc = "Before. New wording of the claim. After."
        return SelectionRewriteSpec(
            documentText: doc, documentTitle: "Changed", range: (doc as NSString).range(of: "New wording of the claim."),
            otherTitle: "Original", counterpart: counterpart, passageWeight: weight, instructions: "Humanize it.")
    }

    func testCounterpartIsSentWithTheBlend() {
        let m = SelectionRewrite.messages(for: spec(weight: 0.5))
        XCTAssertTrue(m.user.contains("<other_passage title=\"Original\">\nOld wording of the claim.\n</other_passage>"))
        XCTAssertTrue(m.system.contains("## Blending with the other version"))
        XCTAssertTrue(m.system.contains("Merge the marked passage and the matching part of “Original” evenly"))
        XCTAssertTrue(m.system.contains("roughly 50% marked passage and 50% “Original”"))
        XCTAssertTrue(m.system.contains("passage or the matching part of the other version"), "facts from the other version are allowed in")
    }

    func testWeightPicksTheBaseOfAPassage() {
        XCTAssertTrue(SelectionRewrite.messages(for: spec(weight: 1)).system.contains("is background only"))
        XCTAssertFalse(SelectionRewrite.messages(for: spec(weight: 1)).system.contains("Aim for roughly"))
        XCTAssertTrue(SelectionRewrite.messages(for: spec(weight: 0.8)).system.contains("Use the marked passage as the base"))
        XCTAssertTrue(SelectionRewrite.messages(for: spec(weight: 0.2)).system.contains("Use the matching part of “Original” as the base"))
        XCTAssertTrue(SelectionRewrite.messages(for: spec(weight: 0)).system.contains("Follow the matching part of “Original” closely"))
    }

    func testNoBlendWithoutAUsefulCounterpart() {
        for counterpart in [nil, "  ", "New wording of the claim."] as [String?] {
            let m = SelectionRewrite.messages(for: spec(weight: 0.5, counterpart: counterpart))
            XCTAssertFalse(m.system.contains("Blending"), "\(String(describing: counterpart))")
            XCTAssertFalse(m.user.contains("<other_passage"))
            XCTAssertTrue(m.system.contains("Stay within about a third of its length"))
        }
    }

    func testAuditMentionsTheOtherVersionWhenBlending() {
        let audit = SelectionRewrite.auditMessages(draft: "x", spec: spec(weight: 0.3))
        XCTAssertTrue(audit.user.contains("or from the matching part of “Original”"))
        XCTAssertTrue(audit.user.contains("<other_passage"))
    }
}
