import XCTest
import AppKit
import DiffactlyCore
@testable import Diffactly

/// Accepted AI rewrites keep what the passage said before (and can put it
/// back or reopen the suggestion), and passages can be linked across the
/// sides, by hand or when a rewrite is accepted.
@MainActor
final class HistoryAndLinkTests: XCTestCase {

    private func document(left: String = "", right: String) -> DiffDocument {
        let doc = DiffDocument(left: left, right: right, persistsSettings: false)
        doc.mode = .edit
        return doc
    }

    /// A suggestion on `passage` with `answers` filed as versions (the last on show).
    @discardableResult
    private func suggest(_ passage: String, _ answers: [String], side: DiffDocument.Side = .right, in doc: DiffDocument) -> AISuggestion {
        let range = (doc.text(for: side) as NSString).range(of: passage)
        XCTAssertNotEqual(range.location, NSNotFound)
        let s = AISuggestion(side: side, range: range, original: passage, status: .ready)
        doc.addSuggestion(s, present: false)
        for text in answers { answer(s, text) }
        return s
    }

    private func answer(_ s: AISuggestion, _ text: String) {
        let token = s.beginAnswer(label: "Humanize · test", basisLabel: nil)
        s.updateAnswer(token) { a in
            a.replacement = text
            a.status = .ready
            a.isComplete = true
        }
        s.answerFinished(token)
    }

    private func substring(_ range: NSRange, on side: DiffDocument.Side, in doc: DiffDocument) -> String {
        (doc.text(for: side) as NSString).substring(with: range)
    }

    // MARK: History

    func testAnAcceptedRewriteKeepsTheOriginalToGoBackTo() throws {
        let doc = document(right: "Intro.\n\nA pivotal sentence.\n\nOutro.")
        let s = suggest("A pivotal sentence.", ["A plain one."], in: doc)
        XCTAssertTrue(doc.acceptSuggestion(s.id))
        let record = try XCTUnwrap(doc.acceptedRewrites.first)
        XCTAssertEqual(record.original, "A pivotal sentence.")
        XCTAssertEqual(record.state, .applied)
        XCTAssertEqual(substring(record.range, on: .right, in: doc), "A plain one.")
        XCTAssertEqual(record.steps.first?.label, "Humanize · test")

        doc.revertRewrite(record.id)
        XCTAssertEqual(doc.rightText, "Intro.\n\nA pivotal sentence.\n\nOutro.")
        let reverted = try XCTUnwrap(doc.acceptedRewrite(id: record.id))
        XCTAssertEqual(reverted.state, .reverted, "the history stays, to switch back")

        doc.showRewriteStep(1, of: record.id)
        XCTAssertEqual(doc.rightText, "Intro.\n\nA plain one.\n\nOutro.")
        XCTAssertEqual(doc.acceptedRewrite(id: record.id)?.state, .applied)
    }

    func testRewritingAnAcceptedPassageAgainKeepsItsFirstOriginal() throws {
        let doc = document(right: "Intro.\n\nFirst words.\n\nOutro.")
        XCTAssertTrue(doc.acceptSuggestion(suggest("First words.", ["Second words."], in: doc).id))
        XCTAssertTrue(doc.acceptSuggestion(suggest("Second words.", ["Third words, longer."], in: doc).id))
        XCTAssertEqual(doc.acceptedRewrites.count, 1)
        let record = try XCTUnwrap(doc.acceptedRewrites.first)
        XCTAssertEqual(record.texts, ["First words.", "Second words.", "Third words, longer."])
        doc.revertRewrite(record.id)
        XCTAssertEqual(doc.rightText, "Intro.\n\nFirst words.\n\nOutro.")
    }

    func testRewritingAWiderPassageCarriesTheHistoryInside() throws {
        let doc = document(right: "One two. Three four.")
        XCTAssertTrue(doc.acceptSuggestion(suggest("Three four.", ["3 4."], in: doc).id))
        XCTAssertTrue(doc.acceptSuggestion(suggest("One two. 3 4.", ["Everything new."], in: doc).id))
        let record = try XCTUnwrap(doc.acceptedRewrites.first)
        XCTAssertEqual(doc.acceptedRewrites.count, 1)
        XCTAssertEqual(record.texts, ["One two. Three four.", "One two. 3 4.", "Everything new."])
    }

    func testHistoryFollowsEditsAndNoticesHandEdits() throws {
        let doc = document(right: "Intro.\n\nOld text.\n\nOutro.")
        XCTAssertTrue(doc.acceptSuggestion(suggest("Old text.", ["New text."], in: doc).id))
        doc.rightText = "Added first. " + doc.rightText
        var record = try XCTUnwrap(doc.acceptedRewrites.first)
        XCTAssertEqual(substring(record.range, on: .right, in: doc), "New text.")
        XCTAssertEqual(record.state, .applied)

        doc.rightText = doc.rightText.replacingOccurrences(of: "New text.", with: "New text, edited.")
        record = try XCTUnwrap(doc.acceptedRewrites.first)
        XCTAssertEqual(record.state, .edited)
        XCTAssertEqual(record.text, "New text, edited.")
        doc.revertRewrite(record.id)
        XCTAssertTrue(doc.rightText.contains("\n\nOld text.\n\n"))
    }

    func testUndoingTheAcceptLeavesTheHistoryOnTheOriginal() throws {
        let original = "Intro.\n\nOld text.\n\nOutro."
        let doc = document(right: original)
        XCTAssertTrue(doc.acceptSuggestion(suggest("Old text.", ["Quite different words here."], in: doc).id))
        doc.rightText = original   // what ⌘Z does to the text
        XCTAssertEqual(doc.acceptedRewrites.first?.state, .reverted)
    }

    func testReopeningBringsBackEveryVersionAndPart() throws {
        let doc = document(right: "Intro.\n\nOne. Two. Three.\n\nOutro.")
        let s = suggest("One. Two. Three.", ["Uno. Dos. Tres.", "Un. Deux. Trois."], in: doc)
        let part = try XCTUnwrap(s.addRefinement(range: (s.replacement as NSString).range(of: "Deux.")))
        answer(part, "Zwei.")
        XCTAssertTrue(doc.acceptSuggestion(s.id))
        XCTAssertEqual(doc.rightText, "Intro.\n\nUn. Zwei. Trois.\n\nOutro.")
        let record = try XCTUnwrap(doc.acceptedRewrites.first)

        let reopened = try XCTUnwrap(doc.reopenRewrite(record.id))
        XCTAssertEqual(doc.rightText, "Intro.\n\nOne. Two. Three.\n\nOutro.")
        XCTAssertTrue(doc.acceptedRewrites.isEmpty, "the step goes back to being a suggestion")
        XCTAssertEqual(doc.suggestions.map(\.id), [reopened.id])
        XCTAssertEqual(reopened.versionCount, 2)
        XCTAssertEqual(reopened.shownVersionNumber, 2)
        XCTAssertEqual(reopened.composedReplacement, "Un. Zwei. Trois.")
        XCTAssertEqual(substring(reopened.range, on: .right, in: doc), "One. Two. Three.")
        XCTAssertTrue(doc.acceptSuggestion(reopened.id), "and can be accepted again")
    }

    func testAcceptAllRecordsEachPassageWhereItEndsUp() {
        let doc = document(right: "Alpha one.\n\nBeta two.\n\nGamma three.")
        suggest("Alpha one.", ["A much longer alpha sentence."], in: doc)
        suggest("Gamma three.", ["G."], in: doc)
        doc.acceptAllSuggestions()
        XCTAssertEqual(doc.rightText, "A much longer alpha sentence.\n\nBeta two.\n\nG.")
        XCTAssertEqual(doc.acceptedRewrites(for: .right).map { substring($0.range, on: .right, in: doc) },
                       ["A much longer alpha sentence.", "G."])
        XCTAssertEqual(doc.acceptedRewrites(for: .right).map(\.original), ["Alpha one.", "Gamma three."])
    }

    func testAcceptedRewritesAreMarkedForClickingNotHovering() throws {
        let doc = document(right: "Old text.")
        XCTAssertTrue(doc.acceptSuggestion(suggest("Old text.", ["New text."], in: doc).id))
        let marks = doc.suggestionMarks(for: .right)
        XCTAssertEqual(marks.map(\.style), [.accepted])
        XCTAssertTrue(marks[0].style.isHistory)
    }

    // MARK: Links

    func testTwoSelectionsAreLinkedWithTheSameCommand() throws {
        let doc = document(left: "Left intro.\n\nThe cat sat.", right: "Right intro.\n\nA feline rested.")
        let left = (doc.leftText as NSString).range(of: "The cat sat.")
        doc.updateSelection(side: .left, selectedText: "The cat sat.", range: left)
        doc.linkSelection()
        XCTAssertEqual(doc.pendingLink?.side, .left)
        XCTAssertTrue(doc.links.isEmpty)
        XCTAssertEqual(doc.linkMarks(for: .left).filter(\.isPending).count, 1)

        let right = (doc.rightText as NSString).range(of: "A feline rested.")
        doc.updateSelection(side: .right, selectedText: "A feline rested.", range: right)
        doc.linkSelection()
        XCTAssertNil(doc.pendingLink)
        let link = try XCTUnwrap(doc.links.first)
        XCTAssertEqual(link.leftText, "The cat sat.")
        XCTAssertEqual(link.rightText, "A feline rested.")
        XCTAssertFalse(link.isAutomatic)
        XCTAssertEqual(doc.lines(of: link.left, on: .left), 3...3)
    }

    func testLinksFollowTheirTextAndGoWithIt() throws {
        let doc = document(left: "Keep.\n\nLeft part.", right: "Right part.")
        doc.link(left: (doc.leftText as NSString).range(of: "Left part."), right: NSRange(location: 0, length: 11))
        doc.leftText = "New first line.\n" + doc.leftText
        let link = try XCTUnwrap(doc.links.first)
        XCTAssertEqual(substring(link.left, on: .left, in: doc), "Left part.")
        doc.rightText = ""
        XCTAssertTrue(doc.links.isEmpty, "a link whose text is gone goes")
    }

    func testLinkedTextIsTheCounterpartForRewrites() throws {
        let doc = document(left: "Something unrelated.\n\nThe cat sat on the mat.", right: "A feline rested upon a rug.\n\nOther.")
        doc.link(left: (doc.leftText as NSString).range(of: "The cat sat on the mat."),
                 right: (doc.rightText as NSString).range(of: "A feline rested upon a rug."))
        let match = try XCTUnwrap(RewriteSession.counterpart(side: .right, range: NSRange(location: 0, length: 10), in: doc))
        XCTAssertEqual(match.text, "The cat sat on the mat.")
        XCTAssertTrue(match.isMarked)
    }

    func testAcceptingARewriteLinksItToWhatItMatchedBefore() throws {
        let doc = document(left: "Intro.\n\nThe results were pivotal for the field.\n\nOutro.",
                           right: "Intro.\n\nThe results were pivotal for our field.\n\nOutro.")
        let s = suggest("The results were pivotal for our field.", ["Our findings matter to researchers."], in: doc)
        XCTAssertTrue(doc.acceptSuggestion(s.id))
        let link = try XCTUnwrap(doc.links.first)
        XCTAssertTrue(link.isAutomatic)
        XCTAssertEqual(link.rightText, "Our findings matter to researchers.")
        XCTAssertEqual(link.leftText, "The results were pivotal for the field.")
        // The words no longer line up, but the link still finds it.
        let range = (doc.rightText as NSString).range(of: "Our findings")
        XCTAssertEqual(RewriteSession.counterpart(side: .right, range: range, in: doc)?.text, "The results were pivotal for the field.")
    }

    func testSwappingSidesSwapsLinkEnds() throws {
        let doc = document(left: "Left.", right: "Right.")
        doc.link(left: NSRange(location: 0, length: 5), right: NSRange(location: 0, length: 6))
        doc.swapSides()
        let link = try XCTUnwrap(doc.links.first)
        XCTAssertEqual(link.leftText, "Right.")
        XCTAssertEqual(link.rightText, "Left.")
    }

    func testLineRanges() {
        let text = "one\ntwo\n\nfour\n" as NSString
        XCTAssertEqual(DiffDocument.range(ofLines: [2], in: text).map { text.substring(with: $0) }, "two")
        XCTAssertEqual(DiffDocument.range(ofLines: [2, 4], in: text).map { text.substring(with: $0) }, "two\n\nfour")
        XCTAssertNil(DiffDocument.range(ofLines: [3], in: text), "a blank line has no text to link")
    }

    // MARK: Saved sessions

    func testHistoryAndLinksComeBackWithASavedSession() throws {
        let doc = document(left: "Matching left text here.", right: "Intro.\n\nOld words.")
        let s = suggest("Old words.", ["New words."], in: doc)
        XCTAssertTrue(doc.acceptSuggestion(s.id))
        doc.link(left: NSRange(location: 0, length: 8), right: (doc.rightText as NSString).range(of: "New words."))
        let linkCount = doc.links.count

        let captured = doc.captureSession(bookmarks: BookmarkCache())
        let tab = try JSONDecoder().decode(SessionManifest.Tab.self, from: JSONEncoder().encode(captured.tab))
        let restored = DiffDocument(left: "", right: "", persistsSettings: false)
        restored.restoreSession(tab, texts: captured.texts, bookmarks: BookmarkCache())

        let record = try XCTUnwrap(restored.acceptedRewrites.first)
        XCTAssertEqual(record.texts, ["Old words.", "New words."])
        XCTAssertNotNil(record.steps.last?.suggestion, "the versions come back too, to reopen")
        XCTAssertEqual(restored.links.count, linkCount)
        XCTAssertNotNil(restored.reopenRewrite(record.id))
        XCTAssertEqual(restored.rightText, "Intro.\n\nOld words.")
    }
}
