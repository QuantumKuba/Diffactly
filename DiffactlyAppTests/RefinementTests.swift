import XCTest
import AppKit
import DiffactlyCore
@testable import Diffactly

/// Rewriting part of a suggestion on its own: each version of the passage
/// keeps its own rewritten parts, each part has versions of its own, and
/// the combination on show is what Compare and Accept use.
@MainActor
final class RefinementTests: XCTestCase {

    private let passage = "The study was pivotal. It showed a clear effect. Results were robust."

    private func document() -> DiffDocument {
        let doc = DiffDocument(left: "", right: "Intro.\n\n\(passage)\n\nOutro.", persistsSettings: false)
        doc.mode = .edit
        return doc
    }

    /// A suggestion on the passage with the model's answers filed as versions.
    private func suggestion(in doc: DiffDocument, answers: [String]) -> AISuggestion {
        let range = (doc.rightText as NSString).range(of: passage)
        let s = AISuggestion(side: .right, range: range, original: passage, status: .ready)
        doc.addSuggestion(s, present: false)
        for text in answers { answer(s, text) }
        return s
    }

    /// As if the model wrote `text` as the next version.
    private func answer(_ s: AISuggestion, _ text: String) {
        let token = s.beginAnswer(label: "Test", basisLabel: nil)
        s.updateAnswer(token) { a in
            a.replacement = text
            a.status = .ready
            a.isComplete = true
        }
        s.answerFinished(token)
    }

    private func range(of text: String, in s: AISuggestion) -> NSRange {
        let r = (s.replacement as NSString).range(of: text)
        XCTAssertNotEqual(r.location, NSNotFound)
        return r
    }

    // MARK: Combining

    func testAPartRewrittenOnItsOwnGoesIntoWhatIsAccepted() throws {
        let doc = document()
        let s = suggestion(in: doc, answers: ["The study mattered. It showed a strong effect. Results held."])
        let part = try XCTUnwrap(s.addRefinement(range: range(of: "It showed a strong effect.", in: s)))
        XCTAssertEqual(part.original, "It showed a strong effect.")
        XCTAssertEqual(s.composedReplacement, "The study mattered. It showed a strong effect. Results held.",
                       "nothing changes until the part has an answer")

        answer(part, "The effect was plain to see.")
        XCTAssertEqual(s.composedReplacement, "The study mattered. The effect was plain to see. Results held.")
        XCTAssertEqual(doc.suggestions.count, 1)
        XCTAssertTrue(doc.acceptSuggestion(s.id))
        XCTAssertEqual(doc.rightText, "Intro.\n\nThe study mattered. The effect was plain to see. Results held.\n\nOutro.")
    }

    func testEachVersionKeepsItsOwnPartsAndEachPartItsOwnPick() throws {
        let doc = document()
        let s = suggestion(in: doc, answers: ["V one. Sentence A1. Tail one.", "V two. Sentence A2. Tail two."])
        XCTAssertEqual(s.shownVersionNumber, 2)
        let part = try XCTUnwrap(s.addRefinement(range: range(of: "V two. Sentence A2.", in: s)))
        answer(part, "First pick.")
        answer(part, "Second pick.")
        answer(part, "Third pick.")
        XCTAssertEqual(part.versionCount, 3)
        part.showVersion(number: 1)
        XCTAssertEqual(s.composedReplacement, "First pick. Tail two.")

        // V1 of the passage has no parts of its own.
        s.showVersion(number: 1)
        XCTAssertTrue(s.refinements.isEmpty)
        XCTAssertEqual(s.composedReplacement, "V one. Sentence A1. Tail one.")
        XCTAssertEqual(s.refinementCount(forVersion: s.versions[1].id), 1)

        // Back on V2, its part is still on the pick made for it.
        s.showVersion(number: 2)
        XCTAssertEqual(s.refinements.map(\.id), [part.id])
        XCTAssertEqual(s.composedReplacement, "First pick. Tail two.")
        XCTAssertEqual(doc.text(applying: s), "Intro.\n\nFirst pick. Tail two.\n\nOutro.", "Compare shows the combination")
    }

    func testAPartCanGoBackToTheVersionsWordingOrBeDropped() throws {
        let doc = document()
        let s = suggestion(in: doc, answers: ["One. Two. Three."])
        let part = try XCTUnwrap(s.addRefinement(range: range(of: "Two.", in: s)))
        answer(part, "Deux.")
        XCTAssertEqual(s.composedReplacement, "One. Deux. Three.")
        part.usesParentWording = true
        XCTAssertEqual(s.composedReplacement, "One. Two. Three.")
        part.usesParentWording = false
        s.removeRefinement(part)
        XCTAssertTrue(s.refinements.isEmpty)
        XCTAssertEqual(s.composedReplacement, "One. Two. Three.")
    }

    func testPartsCantOverlapAndSelectionsAreTracedThroughThem() throws {
        let doc = document()
        let s = suggestion(in: doc, answers: ["One. Two. Three."])
        let part = try XCTUnwrap(s.addRefinement(range: range(of: "Two.", in: s)))
        XCTAssertNil(s.addRefinement(range: range(of: "One. Two.", in: s)), "overlaps the part")
        XCTAssertNil(s.addRefinement(range: NSRange(location: 4, length: 1)), "only whitespace")
        answer(part, "A much longer second sentence.")

        let composed = s.composedReplacement as NSString
        XCTAssertEqual(composed as String, "One. A much longer second sentence. Three.")
        // "Three." moved in the combined text; it's still found in the version.
        let three = composed.range(of: "Three.")
        XCTAssertEqual(s.versionRange(forComposed: three), range(of: "Three.", in: s))
        XCTAssertEqual(s.composedRange(forVersion: range(of: "Three.", in: s)), three)
        XCTAssertNil(s.versionRange(forComposed: composed.range(of: "longer")), "inside the part")
        XCTAssertNotNil(s.addRefinement(range: range(of: "Three.", in: s)))
        XCTAssertEqual(s.refinements.map(\.original), ["Two.", "Three."], "kept in text order")
    }

    func testAcceptWaitsForAPartBeingWritten() throws {
        let doc = document()
        let s = suggestion(in: doc, answers: ["One. Two. Three."])
        let part = try XCTUnwrap(s.addRefinement(range: range(of: "Two.", in: s)))
        answer(part, "Deux.")
        let token = part.beginAnswer(label: "Again", basisLabel: nil)
        part.updateAnswer(token) { $0.replacement = "Zw" }
        XCTAssertTrue(part.status.isRunning)
        XCTAssertEqual(s.composedReplacement, "One. Zw Three.", "the new answer shows as it's written")
        XCTAssertFalse(s.isAcceptable)
        XCTAssertFalse(doc.acceptSuggestion(s.id))

        // Picking the finished version lets it be accepted while the new one is written.
        part.showVersion(number: 1)
        XCTAssertTrue(s.isAcceptable)
        XCTAssertEqual(s.composedReplacement, "One. Deux. Three.")
    }

    func testAnAnswerSetDirectlyBecomesV1WhenPartOfItIsRewritten() throws {
        let doc = document()
        let range = (doc.rightText as NSString).range(of: passage)
        let s = AISuggestion(side: .right, range: range, original: passage, status: .ready)
        s.replacement = "One. Two."
        s.isComplete = true
        doc.addSuggestion(s, present: false)
        XCTAssertNil(s.shownVersionNumber)
        XCTAssertNotNil(s.addRefinement(range: NSRange(location: 5, length: 4)))
        XCTAssertEqual(s.shownVersionNumber, 1)
        XCTAssertEqual(s.versions.map(\.text), ["One. Two."])
    }

    // MARK: From the editor

    func testSelectingInsideASuggestionOffersThatPartInsteadOfReplacingIt() {
        let doc = document()
        let s = suggestion(in: doc, answers: ["The study mattered. It showed a strong effect in practice. Results held."])
        let session = RewriteSession()
        let selected = (doc.rightText as NSString).range(of: "It showed a clear effect.")
        session.suggest(side: .right, range: selected, text: "It showed a clear effect.", document: doc, store: AIStore())

        XCTAssertEqual(doc.suggestions.map(\.id), [s.id], "the passage's suggestion stays")
        XCTAssertEqual(doc.presentedSuggestion?.id, s.id)
        XCTAssertEqual(s.proposedRefinement.map { (s.replacement as NSString).substring(with: $0) }, "It showed a strong effect in practice.")
        XCTAssertEqual(s.versionCount, 1, "nothing is sent until the user starts it")
    }

    func testASelectionOutsideASuggestionStillStartsANewOne() {
        let doc = document()
        let s = suggestion(in: doc, answers: ["Rewritten."])
        let session = RewriteSession()
        let selected = (doc.rightText as NSString).range(of: "Intro.\n\nThe study")
        session.suggest(side: .right, range: selected, text: "Intro.\n\nThe study", document: doc, store: AIStore(), showingOptions: true)
        XCTAssertFalse(doc.suggestions.contains { $0 === s }, "a selection reaching outside the passage replaces it, as before")
    }

    // MARK: The request

    func testAPartIsRewrittenInTheTextAsItWouldRead() throws {
        let doc = document()
        let s = suggestion(in: doc, answers: ["One. Two. Three."])
        let first = try XCTUnwrap(s.addRefinement(range: range(of: "One.", in: s)))
        answer(first, "Uno, longer.")
        let part = try XCTUnwrap(s.addRefinement(range: range(of: "Three.", in: s)))

        let spec = try XCTUnwrap(RewriteSession().refinementSpec(part, of: s, document: doc, store: AIStore()))
        XCTAssertEqual(spec.documentText, "Intro.\n\nUno, longer. Two. Three.\n\nOutro.")
        XCTAssertEqual((spec.documentText as NSString).substring(with: spec.range), "Three.")
        XCTAssertNil(spec.counterpart)
    }

    // MARK: Showing it

    func testTheCardTracesItsSelectionBackToTheCombinedText() throws {
        let doc = document()
        let s = suggestion(in: doc, answers: ["One. Two. Three."])
        let part = try XCTUnwrap(s.addRefinement(range: range(of: "Two.", in: s)))
        answer(part, "Deux.")
        let composed = s.composedReplacement as NSString

        for changes in [false, true] {
            let display = SuggestionDisplay(s, showsChanges: changes, focused: nil)
            let shown = display.string.string as NSString
            XCTAssertTrue(shown.contains("①"), "the part is numbered")
            let three = try XCTUnwrap(display.displayRange(forComposed: composed.range(of: "Three.")))
            XCTAssertEqual(shown.substring(with: three), "Three.")
            XCTAssertEqual(display.composedRange(forDisplay: three), composed.range(of: "Three."))
            // Selecting everything shown covers the combined text (numbers and struck words drop out).
            let all = display.composedRange(forDisplay: NSRange(location: 0, length: shown.length))
            XCTAssertEqual(all, NSRange(location: 0, length: composed.length))
        }
    }

    // MARK: Saved sessions

    func testRewrittenPartsComeBackWithASavedSession() throws {
        let doc = document()
        let s = suggestion(in: doc, answers: ["One. Two. Three.", "Uno. Dos. Tres."])
        s.showVersion(number: 1)
        let part = try XCTUnwrap(s.addRefinement(range: range(of: "Two.", in: s)))
        answer(part, "Deux.")
        answer(part, "Zwei.")
        part.showVersion(number: 1)
        let kept = try XCTUnwrap(s.addRefinement(range: range(of: "Three.", in: s)))
        answer(kept, "Trois.")
        kept.usesParentWording = true

        let captured = doc.captureSession(bookmarks: BookmarkCache())
        let data = try JSONEncoder().encode(captured.tab)
        let tab = try JSONDecoder().decode(SessionManifest.Tab.self, from: data)

        let restored = DiffDocument(left: "", right: "", persistsSettings: false)
        restored.restoreSession(tab, texts: captured.texts, bookmarks: BookmarkCache())
        let back = try XCTUnwrap(restored.suggestions.first)
        XCTAssertEqual(back.shownVersionNumber, 1)
        XCTAssertEqual(back.refinements.map(\.original), ["Two.", "Three."])
        XCTAssertEqual(back.refinements[0].versions.map(\.text), ["Deux.", "Zwei."])
        XCTAssertEqual(back.refinements[0].shownVersionNumber, 1)
        XCTAssertTrue(back.refinements[1].usesParentWording)
        XCTAssertEqual(back.composedReplacement, "One. Deux. Three.")
        XCTAssertEqual(back.refinementCount(forVersion: back.versions[1].id), 0)
    }
}
