import XCTest
import AppKit
import DiffactlyCore
@testable import Diffactly

/// Comments on passages: they follow their text through edits, detach (not
/// vanish) when it's deleted, travel with a swap, and are saved with files.
@MainActor
final class CommentTests: XCTestCase {

    private func document(left: String = "", right: String) -> DiffDocument {
        let doc = DiffDocument(left: left, right: right, persistsSettings: false)
        doc.mode = .edit
        return doc
    }

    @discardableResult
    private func comment(_ passage: String, _ body: String = "A note.", side: DiffDocument.Side = .right, in doc: DiffDocument) -> TextComment {
        let range = (doc.text(for: side) as NSString).range(of: passage)
        XCTAssertNotEqual(range.location, NSNotFound)
        return doc.addComment(side: side, range: range, body: body, present: false)!
    }

    private func anchored(_ c: TextComment, in doc: DiffDocument) -> String {
        (doc.text(for: c.side) as NSString).substring(with: c.range)
    }

    private var tempFolder: URL!

    override func setUp() {
        super.setUp()
        tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("CommentTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempFolder)
        super.tearDown()
    }

    // MARK: Adding

    func testAddingTrimsTheAnchorAndOpensTheComment() {
        let doc = document(right: "Intro.\n  The key claim.  \nOutro.")
        let range = (doc.rightText as NSString).range(of: "  The key claim.  \n")
        let c = try! XCTUnwrap(doc.addComment(side: .right, range: range))
        XCTAssertEqual(anchored(c, in: doc), "The key claim.", "surrounding whitespace is left out")
        XCTAssertEqual(doc.presentedComment?.id, c.id)
        XCTAssertEqual(doc.presentedComment?.startsEditing, true)
        XCTAssertNil(doc.addComment(side: .right, range: NSRange(location: 6, length: 1)), "nothing but whitespace")

        // Closing it before writing anything discards it; a written one stays.
        doc.commentCardClosed(c.id)
        XCTAssertTrue(doc.comments.isEmpty)
        let kept = comment("Outro.", "Check this.", in: doc)
        doc.commentCardClosed(kept.id)
        XCTAssertEqual(doc.comments.map(\.id), [kept.id])
    }

    func testAddingFromTheSelection() {
        let doc = document(right: "One two three.")
        let range = (doc.rightText as NSString).range(of: "two")
        doc.updateSelection(side: .right, selectedText: "two", range: range)
        doc.addCommentForSelection()
        XCTAssertEqual(doc.comments.count, 1)
        XCTAssertEqual(doc.comments.first?.range, range)
        XCTAssertEqual(doc.comments.first?.side, .right)
    }

    // MARK: Following edits

    func testInsertingBeforeMovesTheAnchor() {
        let doc = document(right: "Intro. Target sentence. Outro.")
        let c = comment("Target sentence.", in: doc)
        doc.rightText = "A brand new opening. Intro. Target sentence. Outro."
        XCTAssertEqual(anchored(c, in: doc), "Target sentence.")
        XCTAssertFalse(c.isDetached)
    }

    func testInsertingAfterKeepsTheAnchor() {
        let doc = document(right: "Intro. Target sentence. Outro.")
        let c = comment("Target sentence.", in: doc)
        let before = c.range
        doc.rightText += " And an ending."
        XCTAssertEqual(c.range, before)
        // Typing right against either end doesn't stretch the comment.
        doc.rightText = "Intro. XTarget sentence.Y Outro. And an ending."
        XCTAssertEqual(anchored(c, in: doc), "Target sentence.")
    }

    func testEditingInsideTheAnchorKeepsTheCommentOnTheEditedText() {
        let doc = document(right: "Hello brave world")
        let c = comment("brave", in: doc)
        doc.rightText = "Hello braXve world"
        XCTAssertEqual(anchored(c, in: doc), "braXve")
        XCTAssertEqual(c.quote, "braXve")
        XCTAssertEqual(c.originalQuote, "brave", "the original passage is remembered")
        doc.rightText = "Hello aXve world"   // part of it deleted
        XCTAssertFalse(c.isDetached)
        XCTAssertEqual(anchored(c, in: doc), "aXve")
    }

    func testDeletingTheAnchorDetachesTheComment() {
        let doc = document(right: "Keep this. Delete this sentence. Keep that.")
        let c = comment("Delete this sentence.", "Too wordy.", in: doc)
        doc.rightText = "Keep this.  Keep that."
        XCTAssertTrue(c.isDetached, "the comment stays, detached")
        XCTAssertEqual(doc.comments.map(\.id), [c.id])
        XCTAssertEqual(c.body, "Too wordy.")
        XCTAssertEqual(c.snippet, "Delete this sentence.", "it still shows what it was on")
        XCTAssertTrue(doc.commentMarks(for: .right).isEmpty, "nothing is painted")
        XCTAssertFalse(doc.navigableComments.contains { $0.id == c.id })

        // Undo brings the text back, and the comment with it.
        doc.rightText = "Keep this. Delete this sentence. Keep that."
        XCTAssertFalse(c.isDetached)
        XCTAssertEqual(anchored(c, in: doc), "Delete this sentence.")
    }

    func testOtherOccurrencesDoNotReattachADetachedComment() {
        let doc = document(right: "alpha beta gamma")
        let c = comment("beta", in: doc)
        doc.rightText = "alpha  gamma"
        XCTAssertTrue(c.isDetached)
        doc.rightText = "alpha  gamma delta"
        XCTAssertTrue(c.isDetached)
        doc.rightText = "beta alpha  gamma delta"   // typed elsewhere, but it's the text that came back
        XCTAssertFalse(c.isDetached)
        XCTAssertEqual(anchored(c, in: doc), "beta")
    }

    func testReplacingThePassageMovesOrDetachesTheComment() {
        // An accepted rewrite of just the passage keeps the comment on it.
        let doc = document(right: "An introductory paragraph. A pivotal sentence. A closing paragraph.")
        let c = comment("A pivotal sentence.", in: doc)
        doc.replace(c.range, in: .right, with: "A plain one.")
        XCTAssertFalse(c.isDetached)
        XCTAssertEqual(anchored(c, in: doc), "A plain one.")

        // Different text pasted over everything doesn't make it all commented.
        doc.setText("Something else entirely, and much longer than before.", for: .right)
        XCTAssertTrue(c.isDetached)
        XCTAssertTrue(doc.commentMarks(for: .right).isEmpty)
    }

    func testClearingPastedTextDetachesItsComments() {
        let doc = document(left: "Left side.", right: "Some pasted text.")
        let c = comment("pasted", in: doc)
        doc.clear(.right)
        XCTAssertEqual(doc.comments.map(\.id), [c.id], "comments on pasted text aren't thrown away")
        XCTAssertTrue(c.isDetached)
    }

    func testSwappingTakesCommentsAlong() {
        let doc = document(left: "Left original words.", right: "Right changed passage here.")
        let right = comment("changed passage", in: doc)
        let left = comment("original", side: .left, in: doc)
        doc.swapSides()
        XCTAssertEqual(right.side, .left)
        XCTAssertEqual(left.side, .right)
        XCTAssertEqual(anchored(right, in: doc), "changed passage")
        XCTAssertEqual(anchored(left, in: doc), "original")
        XCTAssertEqual(doc.commentMarks(for: .left).map(\.id), [right.id])
    }

    // MARK: Resolving and navigating

    func testResolvedCommentsAreListedButNotPainted() {
        let doc = document(right: "One. Two. Three.")
        let c = comment("Two.", in: doc)
        doc.setResolved(c.id, true)
        XCTAssertEqual(doc.comments.count, 1)
        XCTAssertEqual(doc.openCommentCount, 0)
        XCTAssertTrue(doc.commentMarks(for: .right).isEmpty)
        doc.showsResolvedComments = true
        XCTAssertEqual(doc.commentMarks(for: .right).map(\.isResolved), [true])
        doc.showsResolvedComments = false
        // Opening one from the list shows it even so.
        doc.revealComment(c.id)
        XCTAssertEqual(doc.commentMarks(for: .right).map(\.id), [c.id])
        XCTAssertEqual(doc.selectionRequest?.range, c.range, "its passage is selected")
    }

    func testNextAndPreviousGoInReadingOrder() {
        let doc = document(left: "Left one.", right: "First. Second. Third.")
        let third = comment("Third.", in: doc)
        let first = comment("First.", in: doc)
        let left = comment("one", side: .left, in: doc)
        let resolved = comment("Second.", in: doc)
        doc.setResolved(resolved.id, true)
        doc.showNextComment()
        XCTAssertEqual(doc.presentedComment?.id, left.id, "the original comes first")
        doc.showNextComment()
        XCTAssertEqual(doc.presentedComment?.id, first.id)
        doc.showNextComment()
        XCTAssertEqual(doc.presentedComment?.id, third.id, "resolved ones are skipped")
        doc.showNextComment()
        XCTAssertEqual(doc.presentedComment?.id, left.id, "and it wraps around")
        doc.showPreviousComment()
        XCTAssertEqual(doc.presentedComment?.id, third.id)
    }

    func testAPinnedCommentClosesTheSuggestionCardButHoverDoesNot() {
        let doc = document(right: "One. Two. Three.")
        let c = comment("Two.", in: doc)
        doc.presentedSuggestion = SuggestionPresentation(id: UUID(), pinned: true)
        doc.presentComment(c.id, pinned: false)
        XCTAssertNil(doc.presentedComment, "pointing at a comment doesn't take over a suggestion card")
        doc.presentComment(c.id, pinned: true)
        XCTAssertEqual(doc.presentedComment?.id, c.id)
        XCTAssertNil(doc.presentedSuggestion)
    }

    func testDeletingClosesThePopover() {
        let doc = document(right: "One. Two.")
        let c = comment("Two.", in: doc)
        doc.revealComment(c.id)
        doc.deleteComment(c.id)
        XCTAssertTrue(doc.comments.isEmpty)
        XCTAssertNil(doc.presentedComment)
    }

    // MARK: Editor paint

    func testEditorPaintsComments() {
        let tv = DiffTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.string = "Before. Commented passage. After."
        let range = (tv.string as NSString).range(of: "Commented passage.")
        tv.commentMarks = [CommentMark(id: UUID(), range: range, isResolved: false)]
        tv.apply(highlights: EditorHighlights())
        let attrs = tv.layoutManager!.temporaryAttributes(atCharacterIndex: range.location + 2, effectiveRange: nil)
        XCTAssertNotNil(attrs[.backgroundColor])
        XCTAssertEqual(attrs[.underlineColor] as? NSColor, DiffPalette.commentNS)
        XCTAssertNil(tv.layoutManager!.temporaryAttributes(atCharacterIndex: 1, effectiveRange: nil)[.underlineStyle])

        // A suggestion on the same text paints over the comment.
        let suggestion = SuggestionMark(id: UUID(), range: range, style: .ready)
        tv.apply(highlights: EditorHighlights(), suggestionMarks: [suggestion])
        let both = tv.layoutManager!.temporaryAttributes(atCharacterIndex: range.location + 2, effectiveRange: nil)
        XCTAssertEqual(both[.underlineColor] as? NSColor, DiffPalette.suggestionUnderline(.ready))

        tv.commentMarks = []
        tv.apply(highlights: EditorHighlights())
        XCTAssertNil(tv.layoutManager!.temporaryAttributes(atCharacterIndex: range.location + 2, effectiveRange: nil)[.underlineStyle])
    }

    // MARK: Saved with files

    private func write(_ text: String, _ name: String) -> URL {
        let url = tempFolder.appendingPathComponent(name)
        try! text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testCommentsOnAFileComeBackWhenItIsReopened() {
        let store = CommentStore(url: tempFolder.appendingPathComponent("Comments.json"))
        let file = write("Intro.\nThe claim we make.\nA sentence to cut.\nOutro.\n", "essay.txt")

        let first = document(right: "")
        first.commentStore = store
        first.open(file, into: .right)
        let kept = comment("The claim we make.", "Needs a source.", in: first)
        let gone = comment("A sentence to cut.", "Cut this?", in: first)
        first.setResolved(gone.id, true)
        first.saveFileComments()

        // The file changed on disk in the meantime.
        try! "A new first line.\nIntro.\nThe claim we make.\nOutro.\n".write(to: file, atomically: true, encoding: .utf8)
        let second = document(right: "")
        second.commentStore = store
        second.open(file, into: .right)
        XCTAssertEqual(Set(second.comments.map(\.id)), [kept.id, gone.id])
        let restored = try! XCTUnwrap(second.comment(id: kept.id))
        XCTAssertEqual(restored.body, "Needs a source.")
        XCTAssertEqual(anchored(restored, in: second), "The claim we make.", "found again despite the new line above")
        let detached = try! XCTUnwrap(second.comment(id: gone.id))
        XCTAssertTrue(detached.isDetached, "its passage is no longer in the file")
        XCTAssertTrue(detached.isResolved)
        XCTAssertEqual(detached.snippet, "A sentence to cut.")
    }

    func testOpeningAnotherFileTakesTheOldFilesCommentsAway() {
        let store = CommentStore(url: tempFolder.appendingPathComponent("Comments.json"))
        let a = write("Alpha text here.", "a.txt")
        let b = write("Beta text here.", "b.txt")
        let doc = document(right: "")
        doc.commentStore = store
        doc.open(a, into: .left)
        let c = comment("Alpha", side: .left, in: doc)
        doc.open(b, into: .left)
        XCTAssertTrue(doc.comments.isEmpty, "they belong to a.txt")
        XCTAssertEqual(store.comments(for: a).map(\.id), [c.id], "and were saved with it")
        doc.open(a, into: .left)
        XCTAssertEqual(doc.comments.map(\.id), [c.id])
        XCTAssertEqual(anchored(doc.comments[0], in: doc), "Alpha")
    }

    func testStoreRoundTripAndRemoval() {
        let store = CommentStore(url: tempFolder.appendingPathComponent("Comments.json"))
        let file = tempFolder.appendingPathComponent("x.md")
        let saved = CommentStore.Saved(id: UUID(), body: "Note", quote: "q", originalQuote: "q0", location: 4,
                                       isResolved: true, isDetached: false, createdAt: Date(timeIntervalSince1970: 1_000),
                                       editedAt: Date(timeIntervalSince1970: 2_000))
        store.save([saved], for: file)
        XCTAssertEqual(store.comments(for: file), [saved])
        store.save([], for: file)
        XCTAssertTrue(store.all().isEmpty, "a file without comments isn't kept")
    }
}
