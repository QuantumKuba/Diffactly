import XCTest
import SwiftUI
import AppKit
import DiffactlyCore
@testable import Diffactly

/// Inline AI suggestions (without a model): the AI panel opens on the
/// selection, suggestions only change the text when accepted, follow their
/// passage through edits, and the session's references follow open tabs and
/// are remembered per project folder.
@MainActor
final class SuggestionTests: XCTestCase {

    private func document(left: String = "", right: String) -> DiffDocument {
        let doc = DiffDocument(left: left, right: right, persistsSettings: false)
        doc.mode = .edit
        return doc
    }

    /// A finished suggestion for `passage` on `side`, as if the model answered `replacement`.
    @discardableResult
    private func suggest(_ passage: String, _ replacement: String, side: DiffDocument.Side = .right, in doc: DiffDocument) -> AISuggestion {
        let range = (doc.text(for: side) as NSString).range(of: passage)
        XCTAssertNotEqual(range.location, NSNotFound)
        let s = AISuggestion(side: side, range: range, original: passage, status: .ready)
        s.replacement = replacement
        s.isComplete = true
        doc.addSuggestion(s)
        return s
    }

    // MARK: The AI panel opens on the selection

    func testSelectionIsTheDefaultTargetWheneverTextIsSelected() {
        let doc = document(left: "Old.", right: "Intro. The chosen sentence. Outro.")
        let range = (doc.rightText as NSString).range(of: "The chosen sentence.")
        doc.updateSelection(side: .right, selectedText: "The chosen sentence.", range: range)
        let session = RewriteSession()
        session.source = .both
        // Opened from the plain "Rewrite with AI…" button, not the selection command.
        doc.showAI(.rewrite)
        session.prepare(for: doc)
        XCTAssertTrue(session.rewritesSelection)
        XCTAssertEqual(session.target, .selection)
        XCTAssertEqual(session.passage?.text, "The chosen sentence.")
        XCTAssertEqual(session.source, .both, "the whole-text choice is kept for when the user picks it")

        // Without a selection the whole-text choice applies.
        doc.updateSelection(side: .right, selectedText: "")
        session.prepare(for: doc)
        XCTAssertFalse(session.rewritesSelection)
        XCTAssertEqual(session.target, .both)
    }

    // MARK: Accepting and rejecting

    func testNothingChangesUntilAccepted() {
        let doc = document(right: "First paragraph.\n\nA pivotal sentence that underscores things.\n\nLast paragraph.")
        let s = suggest("A pivotal sentence that underscores things.", "A plain sentence.", in: doc)
        XCTAssertEqual(doc.rightText, "First paragraph.\n\nA pivotal sentence that underscores things.\n\nLast paragraph.")
        XCTAssertEqual(doc.presentedSuggestion?.id, s.id, "the card opens")
        XCTAssertEqual(doc.suggestionMarks(for: .right).map(\.style), [.ready])
        XCTAssertTrue(doc.suggestionMarks(for: .left).isEmpty)

        XCTAssertTrue(doc.acceptSuggestion(s.id))
        XCTAssertEqual(doc.rightText, "First paragraph.\n\nA plain sentence.\n\nLast paragraph.", "only the passage is replaced")
        XCTAssertTrue(doc.suggestions.isEmpty)
        XCTAssertNil(doc.presentedSuggestion)
        XCTAssertEqual((doc.rightText as NSString).substring(with: doc.selectionRequest!.range), "A plain sentence.", "the new text is selected")
    }

    func testRejectingKeepsTheText() {
        let doc = document(right: "Keep this exact sentence.")
        let s = suggest("exact sentence", "different words", in: doc)
        doc.rejectSuggestion(s.id)
        XCTAssertEqual(doc.rightText, "Keep this exact sentence.")
        XCTAssertTrue(doc.suggestions.isEmpty)
    }

    func testAPendingSuggestionCannotBeAccepted() {
        let doc = document(right: "One. Two. Three.")
        let s = AISuggestion(side: .right, range: (doc.rightText as NSString).range(of: "Two."), original: "Two.")
        s.replacement = "Half an answ"
        doc.addSuggestion(s)
        XCTAssertFalse(s.isReady)
        XCTAssertFalse(doc.acceptSuggestion(s.id))
        XCTAssertEqual(doc.rightText, "One. Two. Three.")
        XCTAssertEqual(doc.suggestionMarks(for: .right).first?.style, .pending)
    }

    func testANewSuggestionReplacesAnOverlappingOne() {
        let doc = document(right: "Alpha beta gamma delta.")
        let first = suggest("beta gamma", "x", in: doc)
        let second = suggest("gamma delta", "y", in: doc)
        XCTAssertEqual(doc.suggestions.map(\.id), [second.id])
        XCTAssertNil(first.job)
    }

    func testAcceptAllReplacesEveryReadyPassage() {
        let doc = document(right: "One leverages. Two delves. Three stays.")
        suggest("One leverages.", "One uses.", in: doc)
        suggest("Two delves.", "Two digs.", in: doc)
        let pending = AISuggestion(side: .right, range: (doc.rightText as NSString).range(of: "Three stays."), original: "Three stays.")
        doc.addSuggestion(pending, present: false)
        doc.acceptAllSuggestions()
        XCTAssertEqual(doc.rightText, "One uses. Two digs. Three stays.")
        XCTAssertEqual(doc.suggestions.map(\.id), [pending.id], "unfinished suggestions stay")
        XCTAssertEqual((doc.rightText as NSString).substring(with: pending.range), "Three stays.", "and still point at their passage")
    }

    // MARK: Following the passage

    func testSuggestionFollowsItsPassageThroughEdits() {
        let doc = document(right: "Intro. Target sentence here. Outro.")
        let s = suggest("Target sentence here.", "Better sentence.", in: doc)
        doc.rightText = "A new opening line. Intro. Target sentence here. Outro."
        XCTAssertEqual((doc.rightText as NSString).substring(with: s.range), "Target sentence here.")
        doc.rightText += " And an ending."
        XCTAssertEqual(s.status, .ready)
        XCTAssertTrue(doc.acceptSuggestion(s.id))
        XCTAssertEqual(doc.rightText, "A new opening line. Intro. Better sentence. Outro. And an ending.")
    }

    func testEditingThePassageMakesTheSuggestionStale() {
        let doc = document(right: "Intro. Target sentence here. Outro.")
        let s = suggest("Target sentence here.", "Better sentence.", in: doc)
        doc.rightText = "Intro. Target phrase here. Outro."
        XCTAssertEqual(s.status, .stale)
        XCTAssertEqual(doc.suggestionMarks(for: .right).first?.style, .stale)
        XCTAssertFalse(doc.acceptSuggestion(s.id))
        XCTAssertEqual(doc.rightText, "Intro. Target phrase here. Outro.")
        // Undoing the edit brings the suggestion back.
        doc.rightText = "Intro. Target sentence here. Outro."
        XCTAssertEqual(s.status, .ready)
    }

    func testReplacingOrSwappingTheTexts() {
        let doc = document(left: "Left text.", right: "Right passage here.")
        let s = suggest("passage", "section", in: doc)
        doc.swapSides()
        XCTAssertEqual(s.side, .left, "the suggestion travels with its text")
        XCTAssertEqual((doc.leftText as NSString).substring(with: s.range), "passage")
        doc.clear(.left)
        XCTAssertTrue(doc.suggestions.isEmpty, "clearing the text drops its suggestions")
    }

    func testPreviewTextAppliesTheSuggestion() {
        let doc = document(right: "Keep. Change me. Keep.")
        let s = suggest("Change me.", "Changed.", in: doc)
        XCTAssertEqual(doc.text(applying: s), "Keep. Changed. Keep.")
        XCTAssertEqual(doc.rightText, "Keep. Change me. Keep.")
    }

    // MARK: Versions

    /// Streams `text` into a new answer the way `RewriteSession` does, without a model.
    @discardableResult
    private func answer(_ s: AISuggestion, _ text: String?, label: String = "Humanize", finish: Bool = true) -> UUID {
        let token = s.beginAnswer(label: label, basisLabel: nil)
        if let text { s.updateAnswer(token) { $0.replacement = text } }
        guard finish else { return token }
        s.updateAnswer(token) { a in
            a.isComplete = true
            a.duration = 3
            a.status = text.map { $0.isEmpty ? .failed("The model returned no text.") : .ready } ?? .failed("Offline")
        }
        s.answerFinished(token)
        return token
    }

    func testRegeneratingAddsAVersionAndAcceptUsesTheOneOnShow() throws {
        let doc = document(right: "Keep. Change me. Keep.")
        let s = AISuggestion(side: .right, range: (doc.rightText as NSString).range(of: "Change me."), original: "Change me.")
        doc.addSuggestion(s)
        answer(s, "First try.", label: "Humanize · Light")
        XCTAssertEqual(s.versionCount, 1, "one answer isn't worth a picker")
        answer(s, "Second try.", label: "Humanize · Strong")
        XCTAssertEqual(s.versions.map(\.text), ["First try.", "Second try."])
        XCTAssertEqual(s.shownVersionNumber, 2, "the newest is on show")
        XCTAssertEqual(s.replacement, "Second try.")

        s.showVersion(number: 1)
        XCTAssertEqual(s.replacement, "First try.")
        XCTAssertEqual(s.label, "Humanize · Light", "the card shows that version's label")
        XCTAssertTrue(s.isReady)
        XCTAssertEqual(doc.text(applying: s), "Keep. First try. Keep.", "Compare shows the version on show")
        XCTAssertTrue(doc.acceptSuggestion(s.id))
        XCTAssertEqual(doc.rightText, "Keep. First try. Keep.")
    }

    func testAFailedVersionLeavesTheEarlierOnesUsable() {
        let doc = document(right: "One. Two. Three.")
        let s = AISuggestion(side: .right, range: (doc.rightText as NSString).range(of: "Two."), original: "Two.")
        doc.addSuggestion(s)
        answer(s, "2.")
        answer(s, nil)
        XCTAssertEqual(s.status, .failed("Offline"), "the failure is on show")
        XCTAssertEqual(s.versionCount, 2, "and listed after the versions")
        XCTAssertEqual(s.shownVersionNumber, 2)
        XCTAssertFalse(s.isReady)

        s.showVersion(number: 1)
        XCTAssertEqual(s.status, .ready)
        XCTAssertEqual(s.attemptStatus, .failed("Offline"))
        s.showVersion(nil)
        XCTAssertEqual(s.status, .failed("Offline"), "the failure can be looked at again")
        s.showVersion(number: 1)
        XCTAssertTrue(doc.acceptSuggestion(s.id))
        XCTAssertEqual(doc.rightText, "One. 2. Three.")
    }

    func testAnEarlierVersionCanBeShownWhileANewOneIsWritten() {
        let s = AISuggestion(side: .right, range: NSRange(location: 0, length: 4), original: "Text")
        answer(s, "V1 text")
        let token = answer(s, "Half", finish: false)
        XCTAssertEqual(s.status, .drafting)
        XCTAssertEqual(s.shownVersionNumber, 2)

        s.showVersion(number: 1)
        XCTAssertEqual(s.replacement, "V1 text")
        XCTAssertTrue(s.isReady, "an earlier version can be accepted while the next one streams")
        XCTAssertEqual(s.attemptStatus, .drafting)
        // The stream keeps going behind it.
        s.updateAnswer(token) { $0.replacement = "Half and the rest" }
        XCTAssertEqual(s.replacement, "V1 text")
        s.updateAnswer(token) { $0.isComplete = true; $0.status = .ready }
        s.answerFinished(token)
        XCTAssertEqual(s.versions.map(\.text), ["V1 text", "Half and the rest"])
        XCTAssertEqual(s.shownVersionNumber, 1, "what the user picked stays on show")
        XCTAssertNil(s.attemptStatus)

        s.showVersion(number: 2)
        XCTAssertEqual(s.replacement, "Half and the rest")
    }

    func testCancellingTheNewVersionGoesBackToTheLastOne() {
        let s = AISuggestion(side: .right, range: NSRange(location: 0, length: 4), original: "Text")
        answer(s, "Kept")
        let token = answer(s, "Unfinish", finish: false)
        XCTAssertTrue(s.canDiscardAttempt)
        s.discardAttempt()
        XCTAssertEqual(s.status, .ready)
        XCTAssertEqual(s.replacement, "Kept")
        XCTAssertEqual(s.versionCount, 1)
        // A late update from the cancelled request goes nowhere.
        s.updateAnswer(token) { $0.replacement = "Late" }
        s.answerFinished(token)
        XCTAssertEqual(s.replacement, "Kept")
        XCTAssertEqual(s.versionCount, 1)
    }

    func testAReplacedRequestCannotWriteIntoTheNextOne() {
        let s = AISuggestion(side: .right, range: NSRange(location: 0, length: 4), original: "Text")
        let old = answer(s, "Old", finish: false)
        answer(s, "New", finish: false)
        s.updateAnswer(old) { $0.replacement = "Old, later" }
        XCTAssertEqual(s.replacement, "New")
    }

    func testEditingThePassageWhileAHiddenVersionStreamsDropsIt() {
        let doc = document(right: "Intro. Target sentence here. Outro.")
        let s = AISuggestion(side: .right, range: (doc.rightText as NSString).range(of: "Target sentence here."), original: "Target sentence here.")
        doc.addSuggestion(s)
        answer(s, "Better sentence.")
        answer(s, "Stream", finish: false)
        s.showVersion(number: 1)
        doc.rightText = "Intro. Target phrase here. Outro."
        XCTAssertEqual(s.status, .stale)
        doc.rightText = "Intro. Target sentence here. Outro."
        XCTAssertEqual(s.status, .ready)
        XCTAssertNil(s.attemptStatus, "the request was cancelled with the edit")
        XCTAssertEqual(s.versionCount, 1)
        XCTAssertTrue(doc.acceptSuggestion(s.id))
        XCTAssertEqual(doc.rightText, "Intro. Better sentence. Outro.")
    }

    func testAnAnswerSetDirectlyBecomesTheFirstVersion() {
        let doc = document(right: "Keep this exact sentence.")
        let s = suggest("exact sentence", "precise line", in: doc)
        answer(s, "plain line")
        XCTAssertEqual(s.versions.map(\.text), ["precise line", "plain line"])
    }

    func testVersionsAreCapped() {
        let s = AISuggestion(side: .right, range: NSRange(location: 0, length: 4), original: "Text")
        answer(s, "first")
        for i in 2...AISuggestion.versionLimit { answer(s, "answer \(i)") }
        let token = answer(s, "newest", finish: false)
        s.showVersion(number: 1)
        s.updateAnswer(token) { $0.isComplete = true; $0.status = .ready }
        s.answerFinished(token)
        XCTAssertEqual(s.versions.count, AISuggestion.versionLimit)
        XCTAssertEqual(s.versions.first?.text, "first", "the version on show is never dropped")
        XCTAssertFalse(s.versions.contains { $0.text == "answer 2" }, "the oldest other one goes")
        XCTAssertEqual(s.versions.last?.text, "newest")
    }

    // MARK: From the AI panel to a suggestion

    func testSheetResultCanBeReviewedInTheText() {
        let doc = document(left: "Old.", right: "Intro. Old claim here. Outro.")
        let range = (doc.rightText as NSString).range(of: "Old claim here.")
        doc.updateSelection(side: .right, selectedText: "Old claim here.", range: range)
        let session = RewriteSession()
        session.prepare(for: doc)
        session.setResultForTesting("New claim.")
        XCTAssertTrue(session.reviewPassageInText(document: doc))
        XCTAssertEqual(doc.rightText, "Intro. Old claim here. Outro.", "reviewing doesn't apply anything")
        let suggestion = try! XCTUnwrap(doc.suggestions.first)
        XCTAssertTrue(suggestion.isReady)
        XCTAssertEqual(suggestion.range, range)
        doc.acceptSuggestion(suggestion.id)
        XCTAssertEqual(doc.rightText, "Intro. New claim. Outro.")
    }

    func testReviewingInTheTextBringsThePassagesVersions() throws {
        let doc = document(left: "Old.", right: "Intro. Old claim here. Outro.")
        let range = (doc.rightText as NSString).range(of: "Old claim here.")
        doc.updateSelection(side: .right, selectedText: "Old claim here.", range: range)
        let session = RewriteSession()
        session.prepare(for: doc)
        session.setResultForTesting("First claim.", label: "Humanize")
        session.setResultForTesting("Second claim.", label: "Paraphrase")
        session.restore(session.versions(for: .rewrite)[0])
        XCTAssertTrue(session.reviewPassageInText(document: doc))
        let suggestion = try XCTUnwrap(doc.suggestions.first)
        XCTAssertEqual(suggestion.versions.map(\.text), ["First claim.", "Second claim."])
        XCTAssertEqual(suggestion.shownVersionNumber, 1, "the version on show in the panel")
        XCTAssertEqual(suggestion.label, "Humanize")
        XCTAssertTrue(suggestion.isReady)
    }

    // MARK: Blending with the other side

    func testSelectionPromptCarriesTheMatchingPassageAndBlend() {
        let doc = document(left: "Intro.\nThe old results were good.\nOutro.", right: "Intro.\nThe new results were excellent.\nOutro.")
        let range = (doc.rightText as NSString).range(of: "The new results were excellent.")
        doc.updateSelection(side: .right, selectedText: "The new results were excellent.", range: range)
        let session = RewriteSession()
        let savedWeight = session.passageWeight
        let savedInclude = session.includeOtherSide
        defer { session.passageWeight = savedWeight; session.includeOtherSide = savedInclude }
        session.includeOtherSide = true
        session.prepare(for: doc)
        XCTAssertEqual(session.passageCounterpart?.text, "The old results were good.")
        XCTAssertTrue(session.canBlendPassage)

        session.passageWeight = 0.5
        let m = session.previewMessages(document: doc, store: AIStore())
        XCTAssertTrue(m.user.contains("<other_passage title=\"Original\">\nThe old results were good.\n</other_passage>"))
        XCTAssertTrue(m.system.contains("evenly"))

        session.includeOtherSide = false
        let without = session.previewMessages(document: doc, store: AIStore())
        XCTAssertFalse(without.user.contains("<other_passage"))
        XCTAssertFalse(without.user.contains("The old results were good."))
    }

    // MARK: Editor tints

    func testEditorPaintsSuggestions() {
        let tv = DiffTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.string = "Before. Suggested passage. After."
        let range = (tv.string as NSString).range(of: "Suggested passage.")
        let mark = SuggestionMark(id: UUID(), range: range, style: .ready)
        tv.apply(highlights: EditorHighlights(), suggestionMarks: [mark])
        let attrs = tv.layoutManager!.temporaryAttributes(atCharacterIndex: range.location + 2, effectiveRange: nil)
        XCTAssertNotNil(attrs[.backgroundColor])
        XCTAssertNotNil(attrs[.underlineStyle])
        XCTAssertNil(tv.layoutManager!.temporaryAttributes(atCharacterIndex: 1, effectiveRange: nil)[.underlineStyle])
        // Clearing the marks removes the paint.
        tv.apply(highlights: EditorHighlights(), suggestionMarks: [])
        XCTAssertNil(tv.layoutManager!.temporaryAttributes(atCharacterIndex: range.location + 2, effectiveRange: nil)[.underlineStyle])
    }

    // MARK: Reference documents

    func testOtherOpenTabsAreListedAutomatically() {
        let own = DiffDocument(left: "own left", right: "own right", persistsSettings: false)
        let other = DiffDocument(left: "other left", right: "", persistsSettings: false)
        other.leftName = "methods.tex"
        let library = ReferenceLibrary(store: ReferenceStore(url: tempURL("refs.json")))
        library.owner = own
        library.syncOpenTabs([own, other])
        XCTAssertEqual(library.tabItems.map(\.text), ["other left"], "the window's own texts and empty sides aren't references")
        XCTAssertEqual(library.documents(excludingFileNames: []).map(\.name), ["methods.tex"])

        // Turned off stays off; edits are followed.
        library.setEnabled(false, id: library.tabItems[0].id)
        other.leftText = "edited"
        library.syncOpenTabs([own, other])
        XCTAssertEqual(library.tabItems.first?.text, "edited")
        XCTAssertEqual(library.tabItems.first?.isEnabled, false)
        // Closed tabs disappear.
        library.syncOpenTabs([own])
        XCTAssertTrue(library.tabItems.isEmpty)
    }

    func testAnOpenTabWinsOverTheSameAttachedFile() async throws {
        let dir = try tempDir()
        try "on disk".write(to: dir.appendingPathComponent("intro.tex"), atomically: true, encoding: .utf8)
        let library = ReferenceLibrary(store: ReferenceStore(url: dir.appendingPathComponent("refs.json")))
        library.add([dir.appendingPathComponent("intro.tex")])
        try await waitFor { library.items.count == 1 }
        let tab = DiffDocument(left: "being edited", right: "", persistsSettings: false)
        tab.leftName = "intro.tex"
        library.syncOpenTabs([tab])
        XCTAssertEqual(library.documents(excludingFileNames: []).map(\.text), ["being edited"])
    }

    func testReferencesAreRememberedPerProjectFolder() async throws {
        let dir = try tempDir()
        let sections = dir.appendingPathComponent("sections")
        try FileManager.default.createDirectory(at: sections, withIntermediateDirectories: true)
        try "Intro".write(to: sections.appendingPathComponent("1_intro.tex"), atomically: true, encoding: .utf8)
        try "Methods".write(to: sections.appendingPathComponent("2_methods.tex"), atomically: true, encoding: .utf8)
        let store = ReferenceStore(url: dir.appendingPathComponent("refs.json"))

        // First window: a file from `dir` is open; the user attaches the folder,
        // removes one file and pastes a note.
        let first = ReferenceLibrary(store: store)
        first.setProjectFolder(dir)
        first.add([sections])
        try await waitFor { first.items.count == 2 }
        first.remove(id: first.items.first { $0.name.hasSuffix("1_intro.tex") }!.id)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("A pasted note", forType: .string)
        first.addFromPasteboard()
        let methodsID = first.items.first { $0.name.hasSuffix("2_methods.tex") }!.id
        first.setEnabled(false, id: methodsID)

        // A file added to the folder later shows up when it's scanned again.
        try "Results".write(to: sections.appendingPathComponent("3_results.tex"), atomically: true, encoding: .utf8)

        // Later window, a file from a subfolder: the project's references come back.
        let second = ReferenceLibrary(store: store)
        second.setProjectFolder(sections)
        try await waitFor { second.items.count == 3 }
        let names = Set(second.items.map(\.name))
        XCTAssertEqual(names, ["2_methods.tex", "3_results.tex", "Pasted text 1"], "the removed file stays removed")
        XCTAssertEqual(second.items.first { $0.name == "2_methods.tex" }?.isEnabled, false, "on/off choices are kept")
        XCTAssertEqual(second.items.first { $0.origin == .pasted }?.text, "A pasted note")

        // An unrelated folder starts empty.
        let third = ReferenceLibrary(store: store)
        third.setProjectFolder(try tempDir())
        XCTAssertTrue(third.items.isEmpty)
    }

    func testProjectFolderComesFromTheOpenFile() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("paper.tex")
        try "Text".write(to: file, atomically: true, encoding: .utf8)
        let doc = document(right: "")
        XCTAssertNil(doc.projectFolder)
        doc.open(file, into: .right)
        XCTAssertEqual(doc.projectFolder, dir.standardizedFileURL)
        doc.clear(.right)
        XCTAssertNil(doc.projectFolder)
    }

    // MARK: Setting up before sending

    /// A suggestion opened on its settings for `passage`, as "Humanize Selection with Options…" does.
    private func setUp(_ passage: String, side: DiffDocument.Side = .right, in doc: DiffDocument, session: RewriteSession, store: AIStore) -> AISuggestion? {
        let range = (doc.text(for: side) as NSString).range(of: passage)
        XCTAssertNotEqual(range.location, NSNotFound)
        session.suggest(side: side, range: range, text: passage, document: doc, store: store, showingOptions: true)
        return doc.suggestions.last
    }

    func testSetupSendsNothingAndKeepsTheText() throws {
        let doc = document(right: "Intro. A pivotal sentence. Outro.")
        let session = RewriteSession()
        let s = try XCTUnwrap(setUp("A pivotal sentence.", in: doc, session: session, store: scratchStore()))
        XCTAssertEqual(s.status, .configuring)
        XCTAssertFalse(s.status.isRunning)
        XCTAssertNil(s.job, "nothing is sent to the model")
        XCTAssertNil(s.settings)
        XCTAssertEqual(s.replacement, "")
        XCTAssertFalse(s.isReady)
        XCTAssertEqual(doc.presentedSuggestion?.id, s.id, "its card opens")
        XCTAssertEqual(doc.suggestionMarks(for: .right).map(\.style), [.pending])
        XCTAssertFalse(doc.acceptSuggestion(s.id))
        XCTAssertEqual(doc.rightText, "Intro. A pivotal sentence. Outro.")
    }

    func testStartingFromSetup() throws {
        let doc = document(right: "Intro. A pivotal sentence. Outro.")
        let session = RewriteSession()
        let store = scratchStore(withModel: true)
        let s = try XCTUnwrap(setUp("A pivotal sentence.", in: doc, session: session, store: store))
        session.startSuggestion(s, document: doc, store: store)
        XCTAssertEqual(s.status, .drafting)
        XCTAssertNotNil(s.job)
        XCTAssertTrue(s.label.contains("test-model"))
        XCTAssertEqual(doc.suggestions.map(\.id), [s.id], "the same suggestion goes on")
        XCTAssertEqual(doc.rightText, "Intro. A pivotal sentence. Outro.")

        // Its settings are remembered, so changing one afterwards is noticed.
        XCTAssertFalse(session.settingsChanged(since: s, store: store))
        session.extraNotes = "British spelling"
        XCTAssertTrue(session.settingsChanged(since: s, store: store))
        session.extraNotes = ""

        doc.rejectSuggestion(s.id)
        XCTAssertNil(s.job, "rejecting stops the request")
        XCTAssertTrue(doc.suggestions.isEmpty)
    }

    func testSetupWithoutAModelWaits() throws {
        let doc = document(right: "Intro. A pivotal sentence. Outro.")
        let session = RewriteSession()
        let store = scratchStore()
        let s = try XCTUnwrap(setUp("A pivotal sentence.", in: doc, session: session, store: store))
        XCTAssertNotNil(session.suggestionBlocker(in: store))
        session.startSuggestion(s, document: doc, store: store)
        XCTAssertEqual(s.status, .configuring)
        XCTAssertNil(s.job)
        XCTAssertFalse(doc.isShowingAI)
    }

    func testCancellingSetupRemovesIt() throws {
        let doc = document(right: "One. Two. Three.")
        let session = RewriteSession()
        let store = scratchStore()
        let s = try XCTUnwrap(setUp("Two.", in: doc, session: session, store: store))
        doc.rejectSuggestion(s.id)
        XCTAssertTrue(doc.suggestions.isEmpty)
        XCTAssertNil(doc.presentedSuggestion)
        XCTAssertTrue(doc.suggestionMarks(for: .right).isEmpty, "its highlight goes too")

        // Dismissing the card (Esc, clicking elsewhere) drops a setup, but not a written suggestion.
        let setup = try XCTUnwrap(setUp("Two.", in: doc, session: session, store: store))
        doc.suggestionCardClosed(setup.id)
        XCTAssertTrue(doc.suggestions.isEmpty)
        let ready = suggest("Three.", "3.", in: doc)
        doc.suggestionCardClosed(ready.id)
        XCTAssertEqual(doc.suggestions.map(\.id), [ready.id])
        XCTAssertNil(doc.presentedSuggestion)
        XCTAssertEqual(doc.rightText, "One. Two. Three.")
    }

    func testEditingThePassageDuringSetup() throws {
        let doc = document(right: "Intro. Target sentence here. Outro.")
        let session = RewriteSession()
        let store = scratchStore(withModel: true)
        let s = try XCTUnwrap(setUp("Target sentence here.", in: doc, session: session, store: store))

        // Edits around the passage move it.
        doc.rightText = "New start. Intro. Target sentence here. Outro."
        XCTAssertEqual((doc.rightText as NSString).substring(with: s.range), "Target sentence here.")
        // An edit inside it keeps the setup (nothing was asked yet) and follows the passage.
        doc.rightText = "New start. Intro. Target phrase here. Outro."
        XCTAssertEqual(s.status, .configuring)
        XCTAssertEqual((doc.rightText as NSString).substring(with: s.range), "Target phrase here.")
        XCTAssertEqual(doc.suggestionMarks(for: .right).map(\.style), [.pending])

        // Starting it asks about the passage as it reads now.
        session.startSuggestion(s, document: doc, store: store)
        let started = try XCTUnwrap(doc.suggestions.first)
        XCTAssertEqual(doc.suggestions.count, 1)
        XCTAssertEqual(started.original, "Target phrase here.")
        XCTAssertEqual(started.status, .drafting)
        XCTAssertEqual(doc.presentedSuggestion?.id, started.id)
        XCTAssertNil(s.job)
        doc.rejectAllSuggestions()
        XCTAssertNil(started.job)
    }

    func testAcceptAllSkipsSetupsAndRejectAllDropsThem() throws {
        let doc = document(right: "One leverages. Two delves. Three stays.")
        let session = RewriteSession()
        suggest("One leverages.", "One uses.", in: doc)
        let setup = try XCTUnwrap(setUp("Two delves.", in: doc, session: session, store: scratchStore()))
        doc.acceptAllSuggestions()
        XCTAssertEqual(doc.rightText, "One uses. Two delves. Three stays.")
        XCTAssertEqual(doc.suggestions.map(\.id), [setup.id], "a setup isn't accepted")
        XCTAssertEqual(setup.status, .configuring)
        XCTAssertEqual((doc.rightText as NSString).substring(with: setup.range), "Two delves.")
        doc.rejectAllSuggestions()
        XCTAssertTrue(doc.suggestions.isEmpty)
        XCTAssertEqual(doc.rightText, "One uses. Two delves. Three stays.")
    }

    func testMenuCommandsCanOpenTheSetup() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: RewriteSession.optionsFirstKey)
        defer { defaults.set(saved, forKey: RewriteSession.optionsFirstKey) }
        let doc = document(right: "Intro. Chosen words. Outro.")
        let session = RewriteSession()
        doc.suggestionHandler = session.suggestionHandler(for: doc)
        let range = (doc.rightText as NSString).range(of: "Chosen words.")
        doc.updateSelection(side: .right, selectedText: "Chosen words.", range: range)

        // ⌥⇧⌘E always opens the settings first.
        RewriteSession.showsOptionsFirst = false
        doc.suggestRewriteForSelection(withOptions: true)
        XCTAssertEqual(doc.suggestions.map(\.status), [.configuring])
        XCTAssertEqual(doc.suggestions.first?.range, range)
        doc.rejectAllSuggestions()

        // With the preference on, so does the plain command.
        RewriteSession.showsOptionsFirst = true
        doc.suggestRewriteForSelection()
        XCTAssertEqual(doc.suggestions.map(\.status), [.configuring])
        XCTAssertNil(doc.suggestions.first?.job)
        doc.rejectAllSuggestions()
    }

    // MARK: Helpers

    /// AI settings kept apart from the user's, optionally with a model that's
    /// never reached (requests are cancelled before they matter).
    private func scratchStore(withModel: Bool = false) -> AIStore {
        let suite = "SuggestionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = AIStore(defaults: defaults)
        if withModel {
            var provider = AIProvider(kind: .custom)
            provider.baseURL = "http://127.0.0.1:9/v1"
            provider.model = "test-model"
            store.providers = [provider]
        }
        return store
    }

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("suggestions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }

    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
