import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// A saved session: the tabs of one window, kept in a `.diffactly` package
/// wherever the user chose. Once saved, it saves itself as the tabs change.
@MainActor
final class ProjectSession {
    let url: URL
    var name: String { url.deletingPathExtension().lastPathComponent }

    /// The session as it stands: as last read or saved, plus the latest state
    /// of tabs that just closed. Its tabs that no window shows (not reopened
    /// yet) are kept just as they are.
    fileprivate(set) var package: SessionPackage
    /// What's on disk (nil before the first save).
    fileprivate var written: SessionPackage?
    fileprivate var members: [Member] = []
    /// Tabs whose windows just closed (see `SessionController.settle`).
    fileprivate var closing: Set<UUID> = []
    fileprivate var lastChange = Date.distantPast
    fileprivate var autosave: Task<Void, Never>?
    /// The last save failed (its error was shown; later ones aren't, until one works).
    fileprivate var failed = false

    fileprivate struct Member {
        weak var document: DiffDocument?
        var changes: AnyCancellable
    }

    fileprivate init(url: URL, package: SessionPackage, isWritten: Bool) {
        self.url = url
        self.package = package
        self.written = isWritten ? package : nil
    }

    /// The open tabs that belong to this session.
    var documents: [DiffDocument] { members.compactMap(\.document) }
}

/// A session in File ▸ Open Recent Session.
struct RecentSession: Codable, Identifiable, Equatable {
    var path: String
    var bookmark: Data
    var id: String { path }
    var name: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
    var folderName: String { ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent }
}

/// Saves the tabs of a window as a session, opens sessions into windows, and
/// keeps them saved: after any change (once things are quiet for a moment),
/// when a tab or window closes, and when the app quits.
///
/// Closing a tab removes it from its session; closing the session's last
/// window (or quitting) keeps every tab, ready for the session to be reopened.
@MainActor
final class SessionController: ObservableObject {
    static let shared = SessionController()

    /// Opens comparison windows (handed over by the menu commands, which
    /// exist from launch on, and by each window).
    private(set) var openWindow: OpenWindowAction?
    @Published private(set) var recents: [RecentSession] = []

    /// Open sessions, by the path of their package.
    private(set) var sessions: [String: ProjectSession] = [:]
    /// Saved tabs waiting for the window opened to show them.
    private var queue: [(session: ProjectSession, tab: UUID)] = []
    /// Sessions asked for before there was a way to open windows.
    private var waiting: [URL] = []
    private var accessed: Set<URL> = []
    private var closeObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    private var isQuitting = false
    private let defaults: UserDefaults
    private let bookmarks = BookmarkCache.shared

    static let autosaveDelay: TimeInterval = 1.5
    /// How long after a tab closes to decide whether its whole window closed.
    static let closeSettleDelay: TimeInterval = 0.5
    static let recentLimit = 12
    private static let recentsKey = "sessions.recent"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.recentsKey),
           let saved = try? JSONDecoder().decode([RecentSession].self, from: data) {
            recents = saved
        }
    }

    /// Takes the action that opens windows; sessions asked for before it was
    /// available (opened from Finder at launch, with no window yet) open now.
    func provide(_ action: OpenWindowAction) {
        guard openWindow == nil else { return }
        openWindow = action
        guard !waiting.isEmpty else { return }
        DispatchQueue.main.async { [self] in
            let urls = waiting
            waiting.removeAll()
            for url in urls { open(url) }
        }
    }

    static func isSession(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "diffactly"
    }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    private static var appVersion: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }

    // MARK: Windows

    /// Called when a comparison window appears. It shows the next saved tab
    /// being opened, the tab it showed before a relaunch (`marker`), or —
    /// a new tab in a session's window — joins that session.
    func documentAppeared(_ document: DiffDocument, window: NSWindow, restoring marker: String) {
        observeClose(of: window, document: document)
        if document.projectSession == nil {
            // (Not `isPristine`: the restored window already has its stored tab name.)
            if !marker.isEmpty, document.url(for: .left) == nil, document.url(for: .right) == nil,
               restore(marker, into: document) {
                // Back where it was before the relaunch.
            } else if document.isPristine, !queue.isEmpty {
                let next = queue.removeFirst()
                load(next.tab, of: next.session, into: document)
                continueOpening(next.session, after: window)
            } else if let session = session(ofTabsBeside: window) {
                join(document, session)
            }
        }
        window.representedURL = document.projectSession?.url
        if !waiting.isEmpty {
            let urls = waiting
            waiting.removeAll()
            for url in urls { open(url, preferring: window) }
        }
    }

    /// The session the other tabs of `window` belong to.
    private func session(ofTabsBeside window: NSWindow) -> ProjectSession? {
        for tab in window.tabbedWindows ?? [] where tab !== window {
            if let session = DocumentRouter.shared.document(for: tab)?.projectSession { return session }
        }
        return nil
    }

    private func observeClose(of window: NSWindow, document: DiffDocument) {
        let id = ObjectIdentifier(window)
        guard closeObservers[id] == nil else { return }
        closeObservers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self, weak document] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let token = self.closeObservers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(token) }
                if let document { self.tabWillClose(document) }
            }
        }
    }

    /// A tab is closing. Whether it leaves its session depends on whether
    /// the rest of the window is closing too, so that's settled a moment later.
    func tabWillClose(_ document: DiffDocument) {
        guard !isQuitting, let session = document.projectSession else { return }
        // Its latest state stays in the package in case the whole window is closing.
        let captured = document.captureSession(bookmarks: bookmarks)
        session.package.replaceTab(captured)
        session.closing.insert(document.sessionTabID)
        leave(document, session)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeSettleDelay) { [weak self, weak session] in
            guard let self, let session else { return }
            self.settle(session)
        }
    }

    private func settle(_ session: ProjectSession) {
        guard !session.closing.isEmpty, !isQuitting else { return }
        let closed = session.closing
        session.closing.removeAll()
        if session.documents.isEmpty {
            // The whole window closed: the session keeps all its tabs.
            save(session)
            session.autosave?.cancel()
            if sessions[Self.key(session.url)] === session { sessions[Self.key(session.url)] = nil }
            queue.removeAll { $0.session === session }
        } else {
            // Single tabs were closed: they leave the session.
            session.package.removeTabs(closed)
            save(session)
        }
    }

    // MARK: Membership

    func join(_ document: DiffDocument, _ session: ProjectSession) {
        if let previous = document.projectSession, previous !== session { leave(document, previous) }
        guard !session.documents.contains(where: { $0 === document }) else { return }
        document.projectSession = session
        var changes: [AnyPublisher<Void, Never>] = [
            document.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            document.contentChanged.eraseToAnyPublisher(),
        ]
        if let rewrite = document.rewriteSession {
            changes.append(rewrite.objectWillChange.map { _ in () }.eraseToAnyPublisher())
            changes.append(rewrite.references.objectWillChange.map { _ in () }.eraseToAnyPublisher())
        }
        let subscription = Publishers.MergeMany(changes).sink { [weak self, weak session] in
            guard let self, let session else { return }
            self.changed(session)
        }
        session.members.append(ProjectSession.Member(document: document, changes: subscription))
        DocumentRouter.shared.window(for: document)?.representedURL = session.url
    }

    private func leave(_ document: DiffDocument, _ session: ProjectSession) {
        session.members.removeAll { $0.document == nil || $0.document === document }
        if document.projectSession === session { document.projectSession = nil }
        DocumentRouter.shared.window(for: document)?.representedURL = nil
    }

    // MARK: Saving

    /// Something in the session changed: save once it's been quiet for a moment.
    private func changed(_ session: ProjectSession) {
        guard !isQuitting else { return }
        session.lastChange = Date()
        guard session.autosave == nil else { return }
        session.autosave = Task { [weak self, weak session] in
            while true {
                guard let session else { return }
                let wait = Self.autosaveDelay - Date().timeIntervalSince(session.lastChange)
                if wait <= 0 { break }
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                if Task.isCancelled { return }
            }
            guard let self, let session else { return }
            session.autosave = nil
            if self.sessions[Self.key(session.url)] === session { self.save(session) }
        }
    }

    /// Writes the session if anything changed since it was last written.
    @discardableResult
    func save(_ session: ProjectSession, reportingErrors: Bool = false) -> Bool {
        session.autosave?.cancel()
        session.autosave = nil
        let package = makePackage(session)
        if package == session.written { return true }
        do {
            try package.write(to: session.url, previous: session.written)
            session.package = package
            session.written = package
            session.failed = false
            return true
        } catch {
            if reportingErrors || !session.failed {
                present("\(error.localizedDescription)\n\nChanges will be saved again with the next edit.",
                        title: "Couldn’t save the session “\(session.name)”")
            }
            session.failed = true
            return false
        }
    }

    /// The open tabs (in tab-bar order), then the saved tabs no window shows.
    private func makePackage(_ session: ProjectSession) -> SessionPackage {
        let open = orderedDocuments(session)
        var tabs: [SessionManifest.Tab] = []
        var texts: [String: String] = [:]
        for document in open {
            let captured = document.captureSession(bookmarks: bookmarks)
            tabs.append(captured.tab)
            texts.merge(captured.texts) { a, _ in a }
        }
        let openIDs = Set(open.map(\.sessionTabID))
        for tab in session.package.manifest.tabs where !openIDs.contains(tab.id) {
            tabs.append(tab)
            for path in [tab.left.textFile, tab.right.textFile] + tab.references.map(\.textFile) {
                texts[path] = session.package.texts[path] ?? ""
            }
        }
        let selected = open.first { DocumentRouter.shared.window(for: $0)?.isKeyWindow == true }
            ?? open.first { document in
                guard let window = DocumentRouter.shared.window(for: document) else { return false }
                return window.tabGroup?.selectedWindow === window
            }
        let active = selected?.sessionTabID ?? session.package.manifest.activeTab
        return SessionPackage(
            manifest: SessionManifest(app: Self.appVersion, activeTab: tabs.contains { $0.id == active } ? active : tabs.first?.id, tabs: tabs),
            texts: texts)
    }

    private func orderedDocuments(_ session: ProjectSession) -> [DiffDocument] {
        let documents = session.documents
        guard let first = documents.first, let window = DocumentRouter.shared.window(for: first) else { return documents }
        let tabOrder = (window.tabbedWindows ?? [window]).compactMap { DocumentRouter.shared.document(for: $0) }
            .filter { tab in documents.contains { $0 === tab } }
        return tabOrder + documents.filter { document in !tabOrder.contains { $0 === document } }
    }

    /// Before quitting: every session gets its latest changes, and keeps all its tabs.
    func saveAllBeforeQuitting() {
        isQuitting = true
        for session in sessions.values where session.written != nil || !session.documents.isEmpty {
            save(session)
        }
    }

    // MARK: Commands

    /// ⌘S: saves the window's session now, or asks where to keep a new one.
    func save(from document: DiffDocument?) {
        guard let document else { return }
        if let session = document.projectSession { save(session, reportingErrors: true) } else { saveAs(from: document) }
    }

    /// ⇧⌘S: saves every tab in the document's window as a new session.
    func saveAs(from document: DiffDocument?) {
        guard let document, let window = DocumentRouter.shared.window(for: document) ?? WindowTabs.currentWindow else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.diffactlySession]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Save Session"
        panel.message = "Saves every tab in this window with its texts, comments, AI versions, references and settings. From then on, changes are saved automatically."
        panel.prompt = "Save"
        if let session = document.projectSession {
            panel.nameFieldStringValue = session.name
            panel.directoryURL = session.url.deletingLastPathComponent()
        } else {
            panel.nameFieldStringValue = Self.suggestedName(for: document)
            if let folder = document.projectFolder { panel.directoryURL = folder }
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            _ = MainActor.assumeIsolated { self?.create(at: url, tabsOf: window, document: document) }
        }
    }

    static func suggestedName(for document: DiffDocument) -> String {
        let custom = document.tabTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        if let name = document.leftName ?? document.rightName { return (name as NSString).deletingPathExtension }
        return "Untitled Session"
    }

    /// Makes a session of the window's tabs at `url` (which the save panel
    /// already agreed to replace) and writes it.
    @discardableResult
    func create(at url: URL, tabsOf window: NSWindow?, document: DiffDocument) -> ProjectSession? {
        let tabs = (window?.tabbedWindows ?? window.map { [$0] } ?? []).compactMap { DocumentRouter.shared.document(for: $0) }
        let documents = tabs.contains { $0 === document } ? tabs : [document]
        let key = Self.key(url)
        if let current = document.projectSession, current === sessions[key] {
            // Saved onto itself: nothing to move.
            return save(current, reportingErrors: true) ? current : nil
        }
        if let existing = sessions[key] {
            // Saving over a session that's open hands its tabs to this one.
            for member in existing.documents { leave(member, existing) }
            existing.autosave?.cancel()
            sessions[key] = nil
        }
        try? FileManager.default.removeItem(at: url)
        let previous = documents.compactMap(\.projectSession)
        let session = ProjectSession(url: url, package: SessionPackage(manifest: SessionManifest(tabs: []), texts: [:]), isWritten: false)
        sessions[key] = session
        for member in documents { join(member, session) }
        guard save(session, reportingErrors: true) else {
            for member in documents { leave(member, session) }
            sessions[key] = nil
            return nil
        }
        // A session whose tabs all moved here stays on disk as it was.
        for old in previous where old.documents.isEmpty {
            old.autosave?.cancel()
            if sessions[Self.key(old.url)] === old { sessions[Self.key(old.url)] = nil }
        }
        noteRecent(url)
        return session
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.diffactlySession]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.title = "Open Session"
        panel.message = "Choose a Diffactly session"
        panel.prompt = "Open"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url) }
    }

    func showInFinder(_ document: DiffDocument?) {
        guard let url = document?.projectSession?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Opening

    /// Opens a session: its tabs go into a window of their own (or the
    /// current one, while it has nothing in it). An open session comes forward.
    func open(_ url: URL, preferring preferredWindow: NSWindow? = nil) {
        guard let openWindow else { waiting.append(url); return }
        if let session = sessions[Self.key(url)] {
            show(session, openWindow: openWindow, preferring: preferredWindow)
            return
        }
        let package: SessionPackage
        do {
            package = try SessionPackage.read(from: url)
        } catch {
            present(error.localizedDescription, title: "Couldn’t open the session")
            return
        }
        guard !package.manifest.tabs.isEmpty else {
            present("“\(url.lastPathComponent)” has no tabs.", title: "Couldn’t open the session")
            return
        }
        let session = ProjectSession(url: url, package: package, isWritten: true)
        sessions[Self.key(url)] = session
        noteRecent(url)
        show(session, openWindow: openWindow, preferring: preferredWindow)
    }

    /// Opens the session's tabs no window shows yet, then brings it forward.
    private func show(_ session: ProjectSession, openWindow: OpenWindowAction, preferring preferredWindow: NSWindow?) {
        let shown = Set(session.documents.map(\.sessionTabID))
        let missing = session.package.manifest.tabs.map(\.id).filter { id in
            !shown.contains(id) && !queue.contains { $0.session === session && $0.tab == id }
        }
        let host = session.documents.lazy.compactMap { DocumentRouter.shared.window(for: $0) }.first
        guard !missing.isEmpty else {
            finishOpening(session)
            return
        }
        queue.append(contentsOf: missing.map { (session, $0) })
        if let host {
            WindowTabs.openTab(joining: host, using: openWindow)
            return
        }
        // A window with nothing in it yet takes the first tab.
        if let window = preferredWindow ?? WindowTabs.currentWindow, (window.tabbedWindows?.count ?? 1) <= 1,
           let document = DocumentRouter.shared.document(for: window), document.isPristine,
           let index = queue.firstIndex(where: { $0.session === session }) {
            let next = queue.remove(at: index)
            load(next.tab, of: session, into: document)
            continueOpening(session, after: window)
        } else {
            WindowTabs.openTab(joining: nil, using: openWindow)
        }
    }

    private func continueOpening(_ session: ProjectSession, after window: NSWindow) {
        if queue.contains(where: { $0.session === session }), let openWindow {
            WindowTabs.openTab(joining: window, using: openWindow)
        } else {
            finishOpening(session)
        }
    }

    /// Selects the tab that was selected when the session was saved.
    private func finishOpening(_ session: ProjectSession) {
        let active = session.package.manifest.activeTab
        let document = session.documents.first { $0.sessionTabID == active } ?? session.documents.first
        if let window = document.flatMap({ DocumentRouter.shared.window(for: $0) }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func load(_ id: UUID, of session: ProjectSession, into document: DiffDocument) {
        guard let tab = session.package.manifest.tabs.first(where: { $0.id == id }),
              !session.documents.contains(where: { $0.sessionTabID == id }) else { return }
        document.restoreSession(tab, texts: session.package.texts, bookmarks: bookmarks)
        join(document, session)
    }

    /// After a relaunch: a restored window shows the session tab it showed before.
    private func restore(_ marker: String, into document: DiffDocument) -> Bool {
        let parts = marker.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[0]) else { return false }
        let session: ProjectSession
        if let open = sessions[parts[1]] {
            session = open
        } else {
            guard let recent = recents.first(where: { $0.path == parts[1] }), let url = resolve(recent),
                  let package = try? SessionPackage.read(from: url) else { return false }
            session = ProjectSession(url: url, package: package, isWritten: true)
            sessions[Self.key(url)] = session
        }
        guard session.package.manifest.tabs.contains(where: { $0.id == id }) else { return false }
        load(id, of: session, into: document)
        return document.projectSession === session
    }

    // MARK: Recent sessions

    func openRecent(_ recent: RecentSession) {
        guard let url = resolve(recent) else {
            recents.removeAll { $0 == recent }
            saveRecents()
            present("It may have been moved, renamed or deleted.", title: "Couldn’t find “\(recent.name)”")
            return
        }
        open(url)
    }

    func clearRecents() {
        recents.removeAll()
        saveRecents()
    }

    /// Labels for the menu: the name, plus its folder where two share a name.
    func menuTitle(for recent: RecentSession) -> String {
        recents.filter { $0.name == recent.name }.count > 1 ? "\(recent.name) — \(recent.folderName)" : recent.name
    }

    private func noteRecent(_ url: URL) {
        let data = (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        guard let data else { return }
        let path = Self.key(url)
        recents.removeAll { $0.path == path }
        recents.insert(RecentSession(path: path, bookmark: data), at: 0)
        if recents.count > Self.recentLimit { recents.removeLast(recents.count - Self.recentLimit) }
        saveRecents()
        // Also in the Dock icon's menu (tests leave the system's list alone).
        if defaults === UserDefaults.standard { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
    }

    /// The session file a recent entry points at, opened for access (nil when it's gone).
    private func resolve(_ recent: RecentSession) -> URL? {
        var stale = false
        let url = (try? URL(resolvingBookmarkData: recent.bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: recent.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))
        guard let url else { return nil }
        if !accessed.contains(url), url.startAccessingSecurityScopedResource() { accessed.insert(url) }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if stale || Self.key(url) != recent.path {
            recents.removeAll { $0 == recent }
            noteRecent(url)
        }
        return url
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recents) { defaults.set(data, forKey: Self.recentsKey) }
    }

    // MARK: Alerts

    private func present(_ message: String, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        if let window = WindowTabs.currentWindow, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - Package edits

extension SessionPackage {
    /// Puts a freshly captured tab in place of its saved version (or adds it).
    mutating func replaceTab(_ captured: CapturedTab) {
        if let old = manifest.tabs.first(where: { $0.id == captured.tab.id }) {
            for path in Self.files(of: old) { texts[path] = nil }
        }
        if let index = manifest.tabs.firstIndex(where: { $0.id == captured.tab.id }) {
            manifest.tabs[index] = captured.tab
        } else {
            manifest.tabs.append(captured.tab)
        }
        texts.merge(captured.texts) { _, new in new }
    }

    mutating func removeTabs(_ ids: Set<UUID>) {
        for tab in manifest.tabs where ids.contains(tab.id) {
            for path in Self.files(of: tab) { texts[path] = nil }
        }
        manifest.tabs.removeAll { ids.contains($0.id) }
        if let active = manifest.activeTab, ids.contains(active) { manifest.activeTab = manifest.tabs.first?.id }
    }

    static func files(of tab: SessionManifest.Tab) -> [String] {
        [tab.left.textFile, tab.right.textFile] + tab.references.map(\.textFile)
    }
}

extension DiffDocument {
    /// What a restored window needs to show this tab again after a relaunch
    /// ("" outside a session).
    var sessionMarker: String {
        projectSession.map { "\(sessionTabID.uuidString)|\($0.url.standardizedFileURL.path)" } ?? ""
    }
}

// MARK: - Menu commands

/// File ▸ Open Session…, Open Recent Session, Save Session, Save Session As…
struct SessionCommands: Commands {
    @ObservedObject var controller: SessionController
    @FocusedObject private var document: DiffDocument?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let _ = controller.provide(openWindow)
        CommandGroup(after: .newItem) {
            Divider()
            Button("Open Session…") { controller.showOpenPanel() }
                .keyboardShortcut("o", modifiers: [.command, .option])
            Menu("Open Recent Session") {
                ForEach(controller.recents) { recent in
                    Button(controller.menuTitle(for: recent)) { controller.openRecent(recent) }
                }
                if !controller.recents.isEmpty { Divider() }
                Button("Clear Menu") { controller.clearRecents() }
                    .disabled(controller.recents.isEmpty)
            }
        }

        // After, not replacing: Close and Close All are in that group.
        CommandGroup(after: .saveItem) {
            Divider()
            Button("Save Session") { controller.save(from: document) }
                .keyboardShortcut("s")
                .disabled(document == nil)
            Button("Save Session As…") { controller.saveAs(from: document) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(document == nil)
            Button("Show Session in Finder") { controller.showInFinder(document) }
                .disabled(document?.projectSession == nil)
        }
    }
}
