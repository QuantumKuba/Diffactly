import XCTest
import AppKit
import DiffactlyCore
@testable import Diffactly

/// Saved sessions: a tab's texts, settings, comments, highlights, suggestions,
/// AI versions and references survive a trip through a `.diffactly` package,
/// the package keeps only what the session uses, and a saved session keeps
/// itself up to date.
@MainActor
final class SessionTests: XCTestCase {

    private var folder: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suiteName = "SessionTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// A window's document with its AI sheet, as ContentView sets them up.
    private func window(left: String = "", right: String = "") -> (DiffDocument, RewriteSession) {
        let doc = DiffDocument(left: left, right: right, persistsSettings: false)
        doc.mode = .edit
        doc.commentStore = nil
        let rewrite = RewriteSession()
        rewrite.references.owner = doc
        doc.rewriteSession = rewrite
        return (doc, rewrite)
    }

    private func range(_ text: String, side: DiffDocument.Side, in doc: DiffDocument) -> NSRange {
        let range = (doc.text(for: side) as NSString).range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound, "“\(text)” isn't in the text")
        return range
    }

    /// A tab with a bit of everything in it.
    private func busyWindow(bookmarks: BookmarkCache) throws -> (DiffDocument, RewriteSession) {
        let (doc, rewrite) = window(
            left: "Intro.\n\nThe first claim is bold.\n\nA second claim.\n\nOutro.",
            right: "Intro.\n\nThe first claim is modest.\n\nA second claim, revised.\n\nOutro.")
        let original = folder.appendingPathComponent("chapter.tex")
        try "Intro.".write(to: original, atomically: true, encoding: .utf8)
        doc.restoreFile(original, name: "chapter.tex", for: .left)
        doc.setTitle("Draft", for: .left)
        doc.setTitle("Final", for: .right)
        doc.setTabTitle("Chapter 3")
        doc.options.ignoreCase = true
        doc.options.ignoredStrings = ["TODO"]
        doc.wrapLines = false
        doc.showsResolvedComments = true

        let open = try XCTUnwrap(doc.addComment(side: .right, range: range("The first claim is modest.", side: .right, in: doc), body: "Too hedged?", present: false))
        let resolved = try XCTUnwrap(doc.addComment(side: .left, range: range("A second claim.", side: .left, in: doc), body: "Fixed.", present: false))
        doc.setResolved(resolved.id, true)
        XCTAssertFalse(open.isResolved)
        doc.markSource(range("The first claim is bold.", side: .left, in: doc), on: .left)

        let suggestion = AISuggestion(side: .right, range: range("A second claim, revised.", side: .right, in: doc), original: "A second claim, revised.", status: .ready)
        suggestion.adoptVersions([
            AISuggestion.Version(text: "Another claim.", label: "Humanize · V1", date: Date(timeIntervalSince1970: 1_000)),
            AISuggestion.Version(text: "A further claim.", label: "Humanize · V2", basisLabel: "Based on the selection", date: Date(timeIntervalSince1970: 2_000), duration: 3.5, didAudit: true, truncation: .answer),
        ], showing: 0)
        doc.addSuggestion(suggestion, present: false)

        rewrite.strength = .strong
        rewrite.extraNotes = "Keep the citations."
        rewrite.source = .right
        rewrite.setResultForTesting("Whole text, take one.", label: "Run 1")
        rewrite.setResultForTesting("Whole text, take two.", label: "Run 2")
        rewrite.setSummaryForTesting("**In short:** the claim softened.", label: "Brief summary")
        rewrite.task = .rewrite

        let reference = folder.appendingPathComponent("notes.md")
        try "Background notes.".write(to: reference, atomically: true, encoding: .utf8)
        rewrite.references.restore([
            .init(id: UUID(), name: "notes.md", kind: .file, isEnabled: true, textFile: "x", filePath: reference.path),
            .init(id: UUID(), name: "Pasted text 1", kind: .pasted, isEnabled: false, textFile: "y"),
        ], texts: ["x": "Background notes.", "y": "Reviewer 2 said so."], bookmarks: bookmarks)
        return (doc, rewrite)
    }

    // MARK: Round trip

    func testATabComesBackWithEverythingInIt() throws {
        let bookmarks = BookmarkCache()
        let (doc, rewrite) = try busyWindow(bookmarks: bookmarks)
        let captured = doc.captureSession(bookmarks: bookmarks)
        XCTAssertNotNil(captured.tab.ai)
        XCTAssertEqual(captured.tab.references.count, 2)
        let url = folder.appendingPathComponent("Thesis.diffactly")
        try SessionPackage(manifest: SessionManifest(tabs: [captured.tab]), texts: captured.texts).write(to: url)

        let read = try SessionPackage.read(from: url)
        XCTAssertEqual(read.texts, captured.texts)
        let (copy, copyRewrite) = window(left: DiffDocument.sampleLeft, right: DiffDocument.sampleRight)
        copy.restoreSession(read.manifest.tabs[0], texts: read.texts, bookmarks: bookmarks)

        XCTAssertEqual(copy.leftText, doc.leftText)
        XCTAssertEqual(copy.rightText, doc.rightText)
        XCTAssertEqual(copy.leftName, "chapter.tex")
        XCTAssertEqual(copy.url(for: .left)?.lastPathComponent, "chapter.tex")
        XCTAssertNil(copy.rightName)
        XCTAssertEqual(copy.title(for: .left), "Draft")
        XCTAssertEqual(copy.title(for: .right), "Final")
        XCTAssertEqual(copy.displayTabTitle, "Chapter 3")
        XCTAssertEqual(copy.sessionTabID, doc.sessionTabID)
        XCTAssertEqual(copy.options, doc.options)
        XCTAssertFalse(copy.wrapLines)
        XCTAssertTrue(copy.showsResolvedComments)

        XCTAssertEqual(copy.comments.map(\.body), ["Too hedged?", "Fixed."])
        XCTAssertEqual(copy.comments.map(\.isResolved), [false, true])
        XCTAssertEqual(copy.comments.map(\.id), doc.comments.map(\.id))
        XCTAssertEqual(copy.comments.map(\.range), doc.comments.map(\.range))
        XCTAssertEqual(copy.sourceMarks.map(\.text), ["The first claim is bold."])

        let suggestion = try XCTUnwrap(copy.suggestions.first)
        XCTAssertEqual(suggestion.versions.map(\.text), ["Another claim.", "A further claim."])
        XCTAssertEqual(suggestion.shownVersionNumber, 1, "the version that was on show")
        XCTAssertEqual(suggestion.replacement, "Another claim.")
        XCTAssertTrue(suggestion.isReady)
        XCTAssertEqual(suggestion.versions[1].truncation, .answer)
        XCTAssertTrue(copy.acceptSuggestion(suggestion.id), "a restored suggestion can be accepted")
        XCTAssertTrue(copy.rightText.contains("Another claim."))

        XCTAssertEqual(copyRewrite.strength, .strong)
        XCTAssertEqual(copyRewrite.extraNotes, "Keep the citations.")
        XCTAssertEqual(copyRewrite.task, .rewrite)
        XCTAssertEqual(copyRewrite.versions(for: .rewrite).map(\.text), ["Whole text, take one.", "Whole text, take two."])
        XCTAssertEqual(copyRewrite.shownVersionNumber(for: .rewrite), 2)
        XCTAssertEqual(copyRewrite.output, "Whole text, take two.")
        XCTAssertEqual(copyRewrite.summary, "**In short:** the claim softened.")
        XCTAssertEqual(copyRewrite.references.attachedItems.map(\.name), ["notes.md", "Pasted text 1"])
        XCTAssertEqual(copyRewrite.references.attachedItems.map(\.isEnabled), [true, false])
        XCTAssertEqual(copyRewrite.references.attachedItems.map(\.text), ["Background notes.", "Reviewer 2 said so."])
        XCTAssertFalse(copyRewrite.references.followsProjectFolder, "a session's references aren't mixed with the folder's")
        withExtendedLifetime(rewrite) {}
    }

    func testARestoredTabSavesExactlyWhatWasRead() throws {
        // Otherwise reopening a session would rewrite it for nothing.
        let bookmarks = BookmarkCache()
        let (doc, rewrite) = try busyWindow(bookmarks: bookmarks)
        let captured = doc.captureSession(bookmarks: bookmarks)
        let url = folder.appendingPathComponent("Same.diffactly")
        try SessionPackage(manifest: SessionManifest(tabs: [captured.tab]), texts: captured.texts).write(to: url)
        let read = try SessionPackage.read(from: url)
        XCTAssertNotNil(read.manifest.tabs[0].ai)

        let (copy, copyRewrite) = window()
        copy.restoreSession(read.manifest.tabs[0], texts: read.texts, bookmarks: bookmarks)
        let again = copy.captureSession(bookmarks: bookmarks)
        XCTAssertEqual(again.tab, read.manifest.tabs[0])
        XCTAssertEqual(again.texts, read.texts)
        withExtendedLifetime((rewrite, copyRewrite)) {}
    }

    func testTextsAreStoredAsPlainFiles() throws {
        let (doc, rewrite) = window(left: "Original words.", right: "Changed words.")
        defer { withExtendedLifetime(rewrite) {} }
        doc.restoreFile(URL(fileURLWithPath: "/tmp/paper.md"), name: "paper.md", for: .left)
        let captured = doc.captureSession(bookmarks: BookmarkCache())
        let url = folder.appendingPathComponent("Plain.diffactly")
        try SessionPackage(manifest: SessionManifest(tabs: [captured.tab]), texts: captured.texts).write(to: url)

        let tabFolder = url.appendingPathComponent("Tabs/\(doc.sessionTabID.uuidString)")
        XCTAssertEqual(try String(contentsOf: tabFolder.appendingPathComponent("left.md"), encoding: .utf8), "Original words.")
        XCTAssertEqual(try String(contentsOf: tabFolder.appendingPathComponent("right.txt"), encoding: .utf8), "Changed words.")
        let json = try String(contentsOf: url.appendingPathComponent("Session.json"), encoding: .utf8)
        XCTAssertFalse(json.contains("Original words."), "texts aren't duplicated in the manifest")
    }

    func testTextExtensions() {
        XCTAssertEqual(DiffDocument.textExtension(for: "chapter.TEX"), "tex")
        XCTAssertEqual(DiffDocument.textExtension(for: nil), "txt")
        XCTAssertEqual(DiffDocument.textExtension(for: "README"), "txt")
        XCTAssertEqual(DiffDocument.textExtension(for: "odd.na me"), "txt")
    }

    // MARK: Finding things again

    func testCommentsAndSuggestionsFindTheirPassageAgain() throws {
        let (doc, rewrite) = window(right: "Alpha.\n\nThe passage.\n\nOmega.")
        defer { withExtendedLifetime(rewrite) {} }
        let tabID = UUID()
        let path = "Tabs/\(tabID.uuidString)/right.txt"
        let tab = SessionManifest.Tab(
            id: tabID, title: "",
            left: .init(title: "Original", textFile: "Tabs/\(tabID.uuidString)/left.txt"),
            right: .init(title: "Changed", textFile: path),
            view: .init(mode: .edit, options: DiffOptions(), collapseUnchanged: false, wrapLines: true,
                        showInsights: false, showsResolvedComments: false, showsComments: true),
            comments: [
                // Its offset is stale (the text was edited outside Diffactly).
                .init(id: UUID(), side: .right, location: 0, length: 12, quote: "The passage.", originalQuote: "The passage.",
                      body: "Moved.", isResolved: false, isDetached: false, created: Date(), edited: Date()),
                .init(id: UUID(), side: .right, location: 3, length: 9, quote: "Gone text", originalQuote: "Gone text",
                      body: "Lost.", isResolved: false, isDetached: false, created: Date(), edited: Date()),
            ],
            highlights: [.init(side: .right, location: 40, length: 6, text: "Omega.")],
            suggestions: [
                .init(side: .right, location: 0, length: 12, original: "The passage.", isStale: false, shownVersion: 0,
                      versions: [.init(text: "A passage.", label: "V1", date: Date(), didAudit: false)]),
                .init(side: .right, location: 0, length: 6, original: "Edited away.", isStale: true, shownVersion: 0,
                      versions: [.init(text: "Something.", label: "V1", date: Date(), didAudit: false)]),
            ],
            ai: nil, references: [])
        doc.restoreSession(tab, texts: [path: "Alpha.\n\nThe passage.\n\nOmega."])

        let found = doc.comments[0]
        XCTAssertFalse(found.isDetached)
        XCTAssertEqual((doc.rightText as NSString).substring(with: found.range), "The passage.")
        XCTAssertTrue(doc.comments[1].isDetached, "a passage that's gone detaches its comment")
        XCTAssertEqual(doc.sourceMarks.first.map { (doc.rightText as NSString).substring(with: $0.range) }, "Omega.")
        XCTAssertTrue(doc.isShowingComments)

        XCTAssertEqual(doc.suggestions.count, 2)
        XCTAssertEqual(doc.suggestions[0].status, .ready)
        XCTAssertEqual((doc.rightText as NSString).substring(with: doc.suggestions[0].range), "The passage.")
        XCTAssertEqual(doc.suggestions[1].status, .stale, "one whose passage was edited can only be regenerated")
    }

    // MARK: The package on disk

    func testRewritingDropsTheFilesOfClosedTabs() throws {
        let (a, _) = window(left: "A left", right: "A right")
        let (b, _) = window(left: "B left", right: "B right")
        let first = a.captureSession(bookmarks: BookmarkCache())
        let second = b.captureSession(bookmarks: BookmarkCache())
        var package = SessionPackage(manifest: SessionManifest(tabs: [first.tab, second.tab]), texts: first.texts.merging(second.texts) { x, _ in x })
        let url = folder.appendingPathComponent("Two.diffactly")
        try package.write(to: url)
        let bFolder = url.appendingPathComponent("Tabs/\(b.sessionTabID.uuidString)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bFolder.path))

        let previous = package
        package.removeTabs([b.sessionTabID])
        try package.write(to: url, previous: previous)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bFolder.path), "a closed tab's folder goes")
        XCTAssertEqual(try SessionPackage.read(from: url).manifest.tabs.map(\.id), [a.sessionTabID])
    }

    func testOnlyChangedTextsAreWrittenAgain() throws {
        let (doc, _) = window(left: "Left", right: "Right")
        let captured = doc.captureSession(bookmarks: BookmarkCache())
        let package = SessionPackage(manifest: SessionManifest(tabs: [captured.tab]), texts: captured.texts)
        let url = folder.appendingPathComponent("Quiet.diffactly")
        try package.write(to: url)
        let left = url.appendingPathComponent(captured.tab.left.textFile)
        try "Touched on disk".write(to: left, atomically: true, encoding: .utf8)

        var changed = package
        changed.texts[captured.tab.right.textFile] = "Right, edited"
        try changed.write(to: url, previous: package)
        XCTAssertEqual(try String(contentsOf: left, encoding: .utf8), "Touched on disk", "unchanged texts aren't rewritten")
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent(captured.tab.right.textFile), encoding: .utf8), "Right, edited")
    }

    func testSessionsFromNewerVersionsAreRefused() throws {
        let url = folder.appendingPathComponent("Future.diffactly")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try #"{"format": 99, "tabs": [], "something": "new"}"#.write(to: url.appendingPathComponent("Session.json"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SessionPackage.read(from: url)) { error in
            XCTAssertTrue(error.localizedDescription.contains("newer version"), error.localizedDescription)
        }
    }

    func testDamagedSessionsAreReported() throws {
        let empty = folder.appendingPathComponent("Empty.diffactly")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try SessionPackage.read(from: empty)) { error in
            XCTAssertTrue(error.localizedDescription.contains("isn’t a Diffactly session"), error.localizedDescription)
        }

        // A text the manifest lists isn't there.
        let (doc, _) = window(left: "L", right: "R")
        let captured = doc.captureSession(bookmarks: BookmarkCache())
        let missing = folder.appendingPathComponent("Missing.diffactly")
        try SessionPackage(manifest: SessionManifest(tabs: [captured.tab]), texts: captured.texts).write(to: missing)
        try FileManager.default.removeItem(at: missing.appendingPathComponent(captured.tab.left.textFile))
        XCTAssertThrowsError(try SessionPackage.read(from: missing)) { error in
            XCTAssertTrue(error.localizedDescription.contains("missing"), error.localizedDescription)
        }

        // A manifest pointing outside the package isn't followed.
        var escaping = captured.tab
        escaping.left.textFile = "../../secret.txt"
        let outside = folder.appendingPathComponent("Outside.diffactly")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try SessionPackage.encoder.encode(SessionManifest(tabs: [escaping])).write(to: outside.appendingPathComponent("Session.json"))
        XCTAssertThrowsError(try SessionPackage.read(from: outside)) { error in
            XCTAssertTrue(error.localizedDescription.contains("outside"), error.localizedDescription)
        }
        XCTAssertFalse(SessionPackage.isSafe("/etc/hosts"))
        XCTAssertTrue(SessionPackage.isSafe("Tabs/x/left.txt"))
    }

    // MARK: Windows a session can open into

    func testOnlyUntouchedWindowsArePristine() throws {
        let (doc, rewrite) = window(left: DiffDocument.sampleLeft, right: DiffDocument.sampleRight)
        XCTAssertTrue(doc.isPristine)
        doc.rightText = "Typed something."
        XCTAssertFalse(doc.isPristine)

        let (other, otherRewrite) = window()
        XCTAssertTrue(other.isPristine)
        otherRewrite.extraNotes = "A note for the model."
        XCTAssertFalse(other.isPristine, "work in the AI sheet counts")
        _ = rewrite
    }

    // MARK: Saving as you go

    func testASavedSessionKeepsItselfUpToDate() async throws {
        let controller = SessionController(defaults: defaults)
        let (doc, rewrite) = window(left: "First draft.", right: "Second draft.")
        defer { withExtendedLifetime(rewrite) {} }
        let url = folder.appendingPathComponent("Live.diffactly")
        let session = try XCTUnwrap(controller.create(at: url, tabsOf: nil, document: doc))
        XCTAssertTrue(doc.projectSession === session)
        XCTAssertEqual(doc.sessionMarker, "\(doc.sessionTabID.uuidString)|\(url.standardizedFileURL.path)")
        XCTAssertEqual(controller.recents.map(\.name), ["Live"])
        XCTAssertEqual(try SessionPackage.read(from: url).texts.values.sorted(), ["First draft.", "Second draft."])

        doc.rightText = "Second draft, edited."
        let comment = try XCTUnwrap(doc.addComment(side: .left, range: range("First", side: .left, in: doc), body: "Earlier?", present: false))
        try await Task.sleep(nanoseconds: UInt64((SessionController.autosaveDelay + 1) * 1_000_000_000))
        let saved = try SessionPackage.read(from: url)
        XCTAssertTrue(saved.texts.values.contains("Second draft, edited."), "saved without asking")
        XCTAssertEqual(saved.manifest.tabs.first?.comments.map(\.id), [comment.id])

        // ⌘S saves right away.
        doc.setTabTitle("Renamed")
        controller.save(from: doc)
        XCTAssertEqual(try SessionPackage.read(from: url).manifest.tabs.first?.title, "Renamed")
    }

    func testSavingOverAnOpenSessionTakesItOver() throws {
        let controller = SessionController(defaults: defaults)
        let (a, _) = window(left: "A", right: "A2")
        let (b, _) = window(left: "B", right: "B2")
        let url = folder.appendingPathComponent("Shared.diffactly")
        let first = try XCTUnwrap(controller.create(at: url, tabsOf: nil, document: a))
        let second = try XCTUnwrap(controller.create(at: url, tabsOf: nil, document: b))
        XCTAssertFalse(first === second)
        XCTAssertNil(a.projectSession, "the old session's tab leaves it")
        XCTAssertTrue(b.projectSession === second)
        XCTAssertEqual(try SessionPackage.read(from: url).manifest.tabs.map(\.id), [b.sessionTabID])

        // Saving a session onto itself keeps it.
        XCTAssertTrue(controller.create(at: url, tabsOf: nil, document: b) === second)
    }

    // MARK: Closing

    private func twoTabSession(_ controller: SessionController) throws -> (a: DiffDocument, b: DiffDocument, url: URL, keep: [RewriteSession]) {
        let (a, ra) = window(left: "A", right: "A2")
        let (b, rb) = window(left: "B", right: "B2")
        let url = folder.appendingPathComponent("Closing.diffactly")
        let session = try XCTUnwrap(controller.create(at: url, tabsOf: nil, document: a))
        controller.join(b, session)
        controller.save(session)
        XCTAssertEqual(try SessionPackage.read(from: url).manifest.tabs.map(\.id), [a.sessionTabID, b.sessionTabID])
        return (a, b, url, [ra, rb])
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: UInt64((SessionController.closeSettleDelay + 0.3) * 1_000_000_000))
    }

    func testClosingATabRemovesItFromTheSession() async throws {
        let controller = SessionController(defaults: defaults)
        let (a, b, url, keep) = try twoTabSession(controller)
        b.rightText = "B2, edited just before closing"
        controller.tabWillClose(b)
        try await settle()
        let saved = try SessionPackage.read(from: url)
        XCTAssertEqual(saved.manifest.tabs.map(\.id), [a.sessionTabID], "the closed tab leaves the session")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("Tabs/\(b.sessionTabID.uuidString)").path))
        XCTAssertNil(b.projectSession)
        withExtendedLifetime(keep) {}
    }

    func testClosingTheWholeWindowKeepsEveryTab() async throws {
        let controller = SessionController(defaults: defaults)
        let (a, b, url, keep) = try twoTabSession(controller)
        b.rightText = "B2, edited just before closing"
        controller.tabWillClose(a)
        controller.tabWillClose(b)
        try await settle()
        let saved = try SessionPackage.read(from: url)
        XCTAssertEqual(saved.manifest.tabs.map(\.id), [a.sessionTabID, b.sessionTabID], "closing the session's window keeps its tabs")
        XCTAssertTrue(saved.texts.values.contains("B2, edited just before closing"), "with their last changes")
        XCTAssertTrue(controller.sessions.isEmpty, "the session is closed")
        withExtendedLifetime(keep) {}
    }
}
