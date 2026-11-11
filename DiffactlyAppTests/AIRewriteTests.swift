import XCTest
import SwiftUI
import AppKit
import DiffactlyCore
@testable import Diffactly

/// Selection rewrites and reference documents, without a model: the editor's
/// minimal replacements, putting a passage back, and loading a paper folder.
@MainActor
final class AIRewriteTests: XCTestCase {

    // MARK: Minimal replacement

    func testChangedRangesCoverOnlyTheEdit() {
        let r = CodeEditor.changedRanges(old: "Hello brave world", new: "Hello new world")
        XCTAssertEqual(r.old, NSRange(location: 6, length: 5))   // "brave"
        XCTAssertEqual(r.new, NSRange(location: 6, length: 3))   // "new"
    }

    func testChangedRangesForInsertDeleteAndIdentity() {
        XCTAssertEqual(CodeEditor.changedRanges(old: "ac", new: "abc").old, NSRange(location: 1, length: 0))
        XCTAssertEqual(CodeEditor.changedRanges(old: "abc", new: "ac").new, NSRange(location: 1, length: 0))
        XCTAssertEqual(CodeEditor.changedRanges(old: "same", new: "same").old.length, 0)
        let all = CodeEditor.changedRanges(old: "abc", new: "xyz")
        XCTAssertEqual(all.old, NSRange(location: 0, length: 3))
    }

    func testChangedRangesNeverSplitComposedCharacters() {
        // 👍🏽 and 👍🏿 share their first UTF-16 units; the edit must cover the whole emoji.
        let old = "ok 👍🏽 done", new = "ok 👍🏿 done"
        let r = CodeEditor.changedRanges(old: old, new: new)
        XCTAssertEqual((old as NSString).substring(with: r.old), "👍🏽")
        XCTAssertEqual((new as NSString).substring(with: r.new), "👍🏿")
        // Repeated letters around the edit stay outside it.
        let e = CodeEditor.changedRanges(old: "café!", new: "cafe!")
        XCTAssertEqual((("café!") as NSString).substring(with: e.old), "é")
    }

    // MARK: The editor applies external edits undoably and selects requests

    private final class TextBox { var text: String; init(_ t: String) { text = t } }

    private func findTextView(in view: NSView) -> DiffTextView? {
        if let tv = view as? DiffTextView { return tv }
        for sub in view.subviews { if let found = findTextView(in: sub) { return found } }
        return nil
    }

    private func editor(_ box: TextBox, request: DiffDocument.SelectionRequest? = nil) -> CodeEditor {
        CodeEditor(
            text: Binding(get: { box.text }, set: { box.text = $0 }),
            highlights: EditorHighlights(),
            placeholder: "",
            wrapLines: true,
            focusRequest: nil,
            focusLines: nil,
            side: .right,
            onFileDrop: { _ in },
            selectionRequest: request
        )
    }

    func testExternalEditReplacesOnlyTheChangedRangeAndUndoes() async throws {
        let box = TextBox("First paragraph.\n\nOld middle.\n\nLast paragraph.")
        let host = NSHostingView(rootView: editor(box))
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(findTextView(in: host))

        box.text = "First paragraph.\n\nNew middle text.\n\nLast paragraph."
        let request = DiffDocument.SelectionRequest(side: .right, range: NSRange(location: 18, length: 16))
        host.rootView = editor(box, request: request)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(textView.string, box.text)
        XCTAssertEqual(textView.selectedRange(), request.range, "the rewritten passage is selected")
        XCTAssertEqual((textView.string as NSString).substring(with: textView.selectedRange()), "New middle text.")

        // Let the run loop close the undo group the edit opened.
        try await Task.sleep(nanoseconds: 100_000_000)
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "First paragraph.\n\nOld middle.\n\nLast paragraph.", "⌘Z restores exactly the replaced passage")
        withExtendedLifetime(window) {}
    }

    // MARK: Putting a passage back

    private func document(left: String, right: String) -> DiffDocument {
        DiffDocument(left: left, right: right)
    }

    /// A session that has "rewritten" a passage, without calling a model.
    private func session(for document: DiffDocument, passage text: String, side: DiffDocument.Side, result: String) -> RewriteSession {
        let range = (document.text(for: side) as NSString).range(of: text)
        document.updateSelection(side: side, selectedText: text, range: range)
        document.aiStartsWithSelection = true
        let session = RewriteSession()
        session.prepare(for: document)
        XCTAssertTrue(session.rewritesSelection)
        XCTAssertEqual(session.passage?.range, range)
        session.setResultForTesting(result)
        return session
    }

    func testReplacingTheSelectionInPlaceKeepsSurroundingSpacing() {
        let doc = document(left: "Original text.", right: "Intro.\n\nA pivotal sentence that underscores things.\n\nOutro.")
        let s = session(for: doc, passage: "\n\nA pivotal sentence that underscores things.\n\n", side: .right, result: "A plain sentence.")
        XCTAssertTrue(s.applyPassage(in: doc, inPlace: true))
        XCTAssertEqual(doc.rightText, "Intro.\n\nA plain sentence.\n\nOutro.")
        XCTAssertEqual(doc.leftText, "Original text.")
        XCTAssertEqual(doc.selectionRequest?.side, .right)
        XCTAssertEqual((doc.rightText as NSString).substring(with: doc.selectionRequest!.range), "\n\nA plain sentence.\n\n")
        s.revert(in: doc)
        XCTAssertEqual(doc.rightText, "Intro.\n\nA pivotal sentence that underscores things.\n\nOutro.")
    }

    func testEditedCopyGoesToTheOtherSideForComparison() {
        let doc = document(left: "Intro. Old claim here. Outro.", right: "something else")
        let s = session(for: doc, passage: "Old claim here.", side: .left, result: "New claim.")
        XCTAssertTrue(s.applyPassage(in: doc, inPlace: false))
        XCTAssertEqual(doc.leftText, "Intro. Old claim here. Outro.", "the source side is untouched")
        XCTAssertEqual(doc.rightText, "Intro. New claim. Outro.")
        XCTAssertEqual(doc.mode, .split)
        s.revert(in: doc)
        XCTAssertEqual(doc.rightText, "something else")
    }

    func testPassageIsFoundAgainAfterTheTextMoved() {
        let doc = document(left: "", right: "One. Target sentence. Two.")
        let s = session(for: doc, passage: "Target sentence.", side: .right, result: "Rewritten.")
        doc.rightText = "Added at the start. One. Target sentence. Two."
        XCTAssertTrue(s.applyPassage(in: doc, inPlace: true))
        XCTAssertEqual(doc.rightText, "Added at the start. One. Rewritten. Two.")
    }

    func testMissingPassageReportsAnError() {
        let doc = document(left: "", right: "One. Target sentence. Two.")
        let s = session(for: doc, passage: "Target sentence.", side: .right, result: "Rewritten.")
        doc.rightText = "Completely different now."
        XCTAssertFalse(s.applyPassage(in: doc, inPlace: true))
        XCTAssertNotNil(s.applyError)
        XCTAssertEqual(doc.rightText, "Completely different now.")
    }

    func testSelectionSpecSeesTheWholeDocumentAndOptionallyTheOtherSide() {
        let doc = document(left: "Earlier version.", right: "Before. Chosen part. After.")
        let s = session(for: doc, passage: "Chosen part.", side: .right, result: "x")
        let store = AIStore()
        let withOther = SelectionRewrite.messages(for: s.selectionSpec(s.passage!, document: doc, store: store))
        XCTAssertTrue(withOther.user.contains("Before. <<<REWRITE_START>>>Chosen part.<<<REWRITE_END>>> After."))
        XCTAssertTrue(withOther.user.contains("Earlier version."))
        s.includeOtherSide = false
        let without = SelectionRewrite.messages(for: s.selectionSpec(s.passage!, document: doc, store: store))
        XCTAssertFalse(without.user.contains("Earlier version."))
        s.includeOtherSide = true
    }

    // MARK: Reference documents

    func testLoadingAPaperFolder() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("refs-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("sections"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("build"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try "Intro \\cite{a}".write(to: root.appendingPathComponent("sections/1_introduction.tex"), atomically: true, encoding: .utf8)
        try "Appendix".write(to: root.appendingPathComponent("sections/10_appendix.tex"), atomically: true, encoding: .utf8)
        try "Background".write(to: root.appendingPathComponent("sections/2_background.tex"), atomically: true, encoding: .utf8)
        try "@article{a}".write(to: root.appendingPathComponent("refs.bib"), atomically: true, encoding: .utf8)
        try "generated".write(to: root.appendingPathComponent("build/main.tex"), atomically: true, encoding: .utf8)
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("figure.png"))

        let loaded = ReferenceLibrary.load([root])
        XCTAssertEqual(loaded.files.map(\.name), ["refs.bib", "sections/1_introduction.tex", "sections/2_background.tex", "sections/10_appendix.tex"])
        XCTAssertEqual(loaded.skipped, 0, "images aren't picked up from folders, so nothing is skipped")
    }

    func testOpenFilesAreNotSentTwice() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("refs-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try "Intro".write(to: root.appendingPathComponent("1_introduction.tex"), atomically: true, encoding: .utf8)
        try "Methods".write(to: root.appendingPathComponent("2_methods.tex"), atomically: true, encoding: .utf8)
        try "@x{}".write(to: root.appendingPathComponent("refs.bib"), atomically: true, encoding: .utf8)

        let library = ReferenceLibrary()
        library.add([root])
        for _ in 0..<100 where library.items.count < 3 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(library.items.count, 3)
        XCTAssertFalse(library.items.first { $0.name == "refs.bib" }!.isEnabled, "bibliographies are opt-in")

        let docs = library.documents(excludingFileNames: ["1_introduction.tex"])
        XCTAssertEqual(docs.map(\.name), ["2_methods.tex"])
    }

    func testPastedAndTabReferences() {
        let library = ReferenceLibrary()
        let other = DiffDocument(left: "Other tab left", right: "Other tab right")
        library.addTab(other, side: .right)
        XCTAssertEqual(library.documents(excludingFileNames: []).map(\.text), ["Other tab right"])
        // Adding the same tab side again updates instead of duplicating.
        other.rightText = "Edited"
        library.addTab(other, side: .right)
        XCTAssertEqual(library.items.count, 1)
        XCTAssertEqual(library.items.first?.text, "Edited")
    }
}
