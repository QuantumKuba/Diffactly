import XCTest
import DiffactlyCore
@testable import Diffactly

/// Text highlighted as a source for AI rewrites: marks follow their text
/// through edits and swaps, and passage rewrites take the other side's
/// highlights as their counterpart instead of the automatic match.
@MainActor
final class SourceMarkTests: XCTestCase {

    private func document(left: String, right: String) -> DiffDocument {
        let doc = DiffDocument(left: left, right: right, persistsSettings: false)
        doc.mode = .edit
        return doc
    }

    private func mark(_ text: String, on side: DiffDocument.Side, in doc: DiffDocument) {
        let range = (doc.text(for: side) as NSString).range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound)
        doc.markSource(range, on: side)
    }

    // MARK: Marks follow their text

    func testMarkMovesWithEditsBeforeItAndSurvivesEditsAfterIt() {
        let doc = document(left: "Alpha. Beta. Gamma.", right: "")
        mark("Beta.", on: .left, in: doc)
        doc.leftText = "Intro! Alpha. Beta. Gamma. Outro."
        let m = try! XCTUnwrap(doc.sourceMarks(for: .left).first)
        XCTAssertEqual(m.text, "Beta.")
        XCTAssertEqual((doc.leftText as NSString).substring(with: m.range), "Beta.")
    }

    func testEditingInsideAMarkKeepsCoveringIt() {
        let doc = document(left: "Alpha. Beta gamma. Delta.", right: "")
        mark("Beta gamma.", on: .left, in: doc)
        doc.leftText = "Alpha. Beta new gamma. Delta."
        XCTAssertEqual(doc.sourceMarks(for: .left).first?.text, "Beta new gamma.")
    }

    func testMarkIsDroppedWhenItsTextIsGone() {
        let doc = document(left: "Alpha. Beta. Gamma.", right: "")
        mark("Beta.", on: .left, in: doc)
        doc.leftText = ""
        XCTAssertTrue(doc.sourceMarks.isEmpty)
    }

    func testSwappingSidesMovesMarksWithTheirText() {
        let doc = document(left: "Left text here.", right: "Right text here.")
        mark("Left text", on: .left, in: doc)
        doc.swapSides()
        XCTAssertTrue(doc.sourceMarks(for: .left).isEmpty)
        XCTAssertEqual(doc.sourceMarks(for: .right).first?.text, "Left text")
    }

    func testOverlappingMarksMergeAndBlankOnesAreIgnored() {
        let doc = document(left: "One two three four five.", right: "")
        mark("One two", on: .left, in: doc)
        mark("two three", on: .left, in: doc)
        doc.markSource(NSRange(location: 3, length: 1), on: .left)   // a space inside the mark
        XCTAssertEqual(doc.sourceMarks(for: .left).map(\.text), ["One two three"])
        let doc2 = document(left: "a   b", right: "")
        doc2.markSource(NSRange(location: 1, length: 3), on: .left)
        XCTAssertTrue(doc2.sourceMarks.isEmpty)
    }

    func testToggleMarksThenUnmarksTheSelection() {
        let doc = document(left: "Keep this sentence. Other.", right: "")
        let range = (doc.leftText as NSString).range(of: "this sentence")
        doc.updateSelection(side: .left, selectedText: "this sentence", range: range)
        doc.toggleSourceMarkForSelection()
        XCTAssertTrue(doc.selectionIsSourceMarked)
        doc.toggleSourceMarkForSelection()
        XCTAssertTrue(doc.sourceMarks.isEmpty)
    }

    func testRemovingByClickPositionAndClearing() {
        let doc = document(left: "Alpha. Beta.", right: "Gamma. Delta.")
        mark("Alpha.", on: .left, in: doc)
        mark("Delta.", on: .right, in: doc)
        doc.handle(.remove(at: 2), on: .left)
        XCTAssertTrue(doc.sourceMarks(for: .left).isEmpty)
        XCTAssertEqual(doc.sourceMarks.count, 1)
        doc.handle(.clearAll, on: .left)
        XCTAssertTrue(doc.sourceMarks.isEmpty)
    }

    // MARK: Rewrites use them

    func testHighlightsOnTheOtherSideReplaceTheAutomaticMatch() {
        let left = "Intro stays.\nThe old results were good.\nA second old line.\nOutro stays."
        let right = "Intro stays.\nThe new results were excellent.\nA second new line.\nOutro stays."
        let doc = document(left: left, right: right)
        doc.scheduleDiff(immediately: true)
        let range = (right as NSString).range(of: "The new results were excellent.")
        XCTAssertEqual(RewriteSession.counterpart(side: .right, range: range, in: doc)?.isMarked, false)

        mark("A second old line.", on: .left, in: doc)
        let marked = try! XCTUnwrap(RewriteSession.counterpart(side: .right, range: range, in: doc))
        XCTAssertTrue(marked.isMarked)
        XCTAssertEqual(marked.text, "A second old line.")
    }

    func testSelectionSpecUsesHighlightsEvenWithoutTheWholeOtherSide() {
        let doc = document(left: "Background. Hand-picked source.", right: "Intro. The passage. Extra highlighted bit.")
        mark("Hand-picked source.", on: .left, in: doc)
        mark("Extra highlighted bit.", on: .right, in: doc)
        let session = RewriteSession()
        session.includeOtherSide = false
        let range = (doc.rightText as NSString).range(of: "The passage.")
        let passage = RewriteSession.Passage(side: .right, range: range, text: "The passage.")
        let counterpart = RewriteSession.counterpart(side: .right, range: range, in: doc)
        let spec = session.selectionSpec(passage, document: doc, store: .shared, counterpart: counterpart, withReferences: false)
        XCTAssertNil(spec.otherText, "the rest of the other side stays out with the toggle off")
        XCTAssertEqual(spec.counterpart, "Hand-picked source.")
        XCTAssertTrue(spec.counterpartIsMarked)
        XCTAssertEqual(spec.markedExcerpts, ["Extra highlighted bit."])

        // Without highlights the toggle decides, as before.
        doc.clearSourceMarks()
        let plain = session.selectionSpec(passage, document: doc, store: .shared,
                                          counterpart: RewriteSession.counterpart(side: .right, range: range, in: doc), withReferences: false)
        XCTAssertNil(plain.counterpart)
        XCTAssertFalse(plain.counterpartIsMarked)
        XCTAssertTrue(plain.markedExcerpts.isEmpty)
        session.includeOtherSide = true
    }

    func testBasisLabelMentionsHighlights() {
        let doc = "Intro. The passage. Outro."
        let spec = SelectionRewriteSpec(documentText: doc, range: (doc as NSString).range(of: "The passage."),
                                        counterpart: "Picked.", counterpartIsMarked: true, markedExcerpts: ["Outro."],
                                        passageWeight: 0.5, instructions: "")
        XCTAssertEqual(RewriteSession.basisLabel(spec, weight: 0.5, otherTitle: "Original"),
                       "Even mix with Original (highlighted) · 1 highlighted excerpt")
    }

    // MARK: Comments steer passage rewrites

    func testOpenCommentsOnThePassageBecomeNotes() {
        let doc = document(left: "", right: "Intro. The passage here. Outro.")
        let ns = doc.rightText as NSString
        doc.addComment(side: .right, range: ns.range(of: "passage"), body: "Too formal.", present: false)
        doc.addComment(side: .right, range: ns.range(of: "Outro."), body: "Elsewhere.", present: false)
        doc.addComment(side: .right, range: ns.range(of: "The"), body: "Done already.", present: false)?.isResolved = true
        let session = RewriteSession()
        session.extraNotes = "British spelling."
        let range = ns.range(of: "The passage here.")
        let passage = RewriteSession.Passage(side: .right, range: range, text: "The passage here.")
        let spec = session.selectionSpec(passage, document: doc, store: .shared, withReferences: false)
        XCTAssertTrue(spec.extraNotes.hasPrefix("British spelling.\n\n"), spec.extraNotes)
        XCTAssertTrue(spec.extraNotes.contains("Too formal."))
        XCTAssertFalse(spec.extraNotes.contains("Elsewhere."))
        XCTAssertFalse(spec.extraNotes.contains("Done already."), "resolved comments are left out")
    }
}
