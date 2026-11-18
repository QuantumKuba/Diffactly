import Foundation
import AppKit
import DiffactlyCore

/// The supplementary documents attached to one window's AI session, such as
/// the other `.tex` files of the paper being edited. They're sent as
/// background with every rewrite and summary while enabled.
///
/// The other open tabs are listed automatically (and follow their edits).
/// Files, folders and pasted text the user attaches are remembered for the
/// project folder of the open file, and come back the next time a file from
/// that folder (or one inside it) is opened.
@MainActor
final class ReferenceLibrary: ObservableObject {

    struct Item: Identifiable, Equatable {
        enum Origin: Equatable {
            case file(URL)
            /// Another open comparison tab (followed live while it stays open).
            case tab(ObjectIdentifier, DiffDocument.Side)
            case pasted
        }

        var id = UUID()
        var name: String
        var text: String
        var origin: Origin
        var isEnabled = true
        var modified: Date?
        /// For a tab, the file open on that side (if any).
        var tabFileName: String?

        /// The file this text is, if any: a reference file, or the file open in a tab.
        var fileName: String? {
            switch origin {
            case .file(let url): return url.lastPathComponent
            case .tab: return tabFileName
            case .pasted: return nil
            }
        }

        var isTab: Bool { if case .tab = origin { return true } else { return false } }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isLoading = false
    @Published var lastMessage: String?
    /// The folder whose saved references this library follows (nil while no
    /// file is open in the window).
    @Published private(set) var projectFolder: URL?

    /// This window's document: its own texts are never references.
    weak var owner: DiffDocument?

    private let store: ReferenceStore
    /// The key the current project is saved under (its folder, or the
    /// enclosing folder it was first saved for).
    private var projectKey: String?
    /// Files and folders the user added, by URL, with bookmarks that reopen
    /// them after a relaunch. Folders are scanned again when restored.
    private var sources: [URL: Data] = [:]
    /// Reference files the user removed from a folder they added.
    private var removedPaths: Set<String> = []
    /// Security-scoped URLs opened from bookmarks (released on deinit).
    private var accessed: [URL] = []
    /// False once the list comes from a saved session: it's kept with the
    /// session, and the folder's remembered references don't merge into it.
    private(set) var followsProjectFolder = true

    /// Prose-like files picked up when a whole folder is added.
    nonisolated static let folderExtensions: Set<String> = ["tex", "ltx", "bib", "md", "markdown", "mdx", "txt", "text", "rst", "org", "typ", "adoc", "asciidoc"]
    /// Folders that hold build output rather than sources.
    nonisolated static let skippedFolders: Set<String> = ["node_modules", "build", "out", "dist", "_minted", "__pycache__", "venv", ".venv"]
    nonisolated static let maxFileSize = 2_000_000
    nonisolated static let maxFiles = 400

    init(store: ReferenceStore = .shared) {
        self.store = store
    }

    deinit {
        for url in accessed { url.stopAccessingSecurityScopedResource() }
    }

    // MARK: Reading

    /// Enabled documents, minus any file that is already open in this window
    /// (it's in the prompt anyway, possibly in a newer version) and any file
    /// another tab has open (that tab's live text is used instead).
    func documents(excludingFileNames open: Set<String>) -> [ReferenceDocument] {
        items.filter { $0.isEnabled && !isOpen($0, open) && !isSuperseded($0) }
            .map { ReferenceDocument(name: $0.name, text: $0.text) }
    }

    func isOpen(_ item: Item, _ open: Set<String>) -> Bool {
        guard let name = item.fileName else { return false }
        return open.contains(name)
    }

    /// A reference file that another tab has open: the tab's text wins.
    func isSuperseded(_ item: Item) -> Bool {
        guard case .file = item.origin, let name = item.fileName else { return false }
        return items.contains { $0.isTab && $0.isEnabled && $0.tabFileName == name }
    }

    func characterCount(excludingFileNames open: Set<String>) -> Int {
        items.reduce(0) { $0 + ($1.isEnabled && !isOpen($1, open) && !isSuperseded($1) ? $1.text.count : 0) }
    }

    var hasEnabledItems: Bool { items.contains(where: \.isEnabled) }

    /// Items the user attached (not the automatic tabs).
    var attachedItems: [Item] { items.filter { !$0.isTab } }
    var tabItems: [Item] { items.filter(\.isTab) }

    // MARK: Editing the list

    func setEnabled(_ enabled: Bool, id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].isEnabled != enabled else { return }
        items[i].isEnabled = enabled
        if !items[i].isTab { persist() }
    }

    func setAllEnabled(_ enabled: Bool) {
        var changed = false
        for i in items.indices where items[i].isEnabled != enabled {
            items[i].isEnabled = enabled
            changed = true
        }
        if changed { persist() }
    }

    func remove(id: UUID) {
        guard let item = items.first(where: { $0.id == id }), !item.isTab else { return }
        if case .file(let url) = item.origin {
            if sources.removeValue(forKey: url) == nil { removedPaths.insert(url.standardizedFileURL.path) }
        }
        items.removeAll { $0.id == id }
        persist()
    }

    /// Removes everything the user attached; open tabs stay listed.
    func removeAll() {
        items.removeAll { !$0.isTab }
        sources.removeAll()
        removedPaths.removeAll()
        persist()
    }

    func addFromPasteboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastMessage = "The clipboard has no text."
            return
        }
        let number = items.filter { $0.origin == .pasted }.count + 1
        items.append(Item(name: "Pasted text \(number)", text: text, origin: .pasted))
        persist()
    }

    func addTab(_ document: DiffDocument, side: DiffDocument.Side) {
        let origin = Item.Origin.tab(ObjectIdentifier(document), side)
        let name = (side == .left ? document.leftName : document.rightName)
            ?? "\(document.displayTabTitle) · \(document.title(for: side))"
        if let i = items.firstIndex(where: { $0.origin == origin }) {
            items[i].text = document.text(for: side)
            items[i].name = name
            items[i].tabFileName = side == .left ? document.leftName : document.rightName
        } else {
            items.append(Item(name: name, text: document.text(for: side), origin: origin,
                              tabFileName: side == .left ? document.leftName : document.rightName))
        }
    }

    /// Lists every side of every other open tab that has text, follows their
    /// edits, and drops tabs that were closed. A tab the user turned off stays off.
    func syncOpenTabs(_ documents: [DiffDocument]? = nil) {
        let others = (documents ?? DocumentRouter.shared.documents).filter { $0 !== owner }
        var wanted: [Item.Origin] = []
        for document in others {
            for side in [DiffDocument.Side.left, .right] where !document.text(for: side).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let origin = Item.Origin.tab(ObjectIdentifier(document), side)
                wanted.append(origin)
                let name = (side == .left ? document.leftName : document.rightName)
                    ?? "\(document.displayTabTitle) · \(document.title(for: side))"
                let fileName = side == .left ? document.leftName : document.rightName
                if let i = items.firstIndex(where: { $0.origin == origin }) {
                    if items[i].text != document.text(for: side) { items[i].text = document.text(for: side) }
                    if items[i].name != name { items[i].name = name }
                    if items[i].tabFileName != fileName { items[i].tabFileName = fileName }
                } else {
                    items.append(Item(name: name, text: document.text(for: side), origin: origin, tabFileName: fileName))
                }
            }
        }
        if items.contains(where: { $0.isTab && !wanted.contains($0.origin) }) {
            items.removeAll { $0.isTab && !wanted.contains($0.origin) }
        }
    }

    /// Lets the user pick files and/or folders.
    func addViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose reference files, or a folder such as your paper’s project folder"
        panel.prompt = "Add"
        if let projectFolder { panel.directoryURL = projectFolder }
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    /// Adds files, and the prose files inside folders (recursively).
    func add(_ urls: [URL]) {
        for url in urls {
            sources[url] = Self.bookmark(for: url) ?? Data()
            removedPaths.remove(url.standardizedFileURL.path)
        }
        load(urls, states: [:], removed: [], announce: true)
    }

    /// Re-reads files changed on disk and pulls the current text of the
    /// other tabs, so a request always sees the latest versions.
    func refresh() {
        syncOpenTabs()
        for i in items.indices {
            guard case .file(let url) = items[i].origin else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard modified != items[i].modified, let text = try? DiffDocument.readText(url) else { continue }
            items[i].text = text
            items[i].modified = modified
        }
    }

    // MARK: Remembering references per project folder

    /// Follows the window's project folder: restores what was saved for it
    /// (or for a folder it's inside), or saves what's attached now under it.
    func setProjectFolder(_ folder: URL?) {
        let folder = folder?.standardizedFileURL
        guard folder != projectFolder else { return }
        projectFolder = folder
        guard let folder, followsProjectFolder else { projectKey = nil; return }
        if let found = store.project(for: folder) {
            projectKey = found.key
            restore(found.project)
        } else {
            projectKey = folder.path
            if !attachedItems.isEmpty { persist() }
        }
    }

    private func restore(_ saved: ReferenceStore.Project) {
        var urls: [URL] = []
        for data in saved.sources {
            guard let url = Self.resolve(data) else { continue }
            if url.startAccessingSecurityScopedResource() { accessed.append(url) }
            if sources[url] == nil { sources[url] = data }
            urls.append(url)
        }
        removedPaths.formUnion(saved.removed)
        for pasted in saved.pasted where !items.contains(where: { $0.id == pasted.id }) {
            items.append(Item(id: pasted.id, name: pasted.name, text: pasted.text, origin: .pasted, isEnabled: pasted.isEnabled))
        }
        let count = saved.pasted.count
        if urls.isEmpty {
            if count > 0 { lastMessage = "Restored the references saved for this folder." }
        } else {
            load(urls, states: saved.states, removed: removedPaths, announce: false)
        }
    }

    /// Saves the attached references for the current project folder.
    private func persist() {
        guard let projectKey else { return }
        let fileStates = Dictionary(items.compactMap { item -> (String, Bool)? in
            guard case .file(let url) = item.origin else { return nil }
            return (url.standardizedFileURL.path, item.isEnabled)
        }, uniquingKeysWith: { a, _ in a })
        let pasted = items.filter { $0.origin == .pasted }.map { ReferenceStore.Pasted(id: $0.id, name: $0.name, text: $0.text, isEnabled: $0.isEnabled) }
        let project = ReferenceStore.Project(
            sources: sources.keys.sorted { $0.path < $1.path }.compactMap { sources[$0].flatMap { $0.isEmpty ? nil : $0 } },
            states: fileStates, removed: removedPaths.sorted(), pasted: pasted, saved: Date())
        store.save(project.isEmpty ? nil : project, key: projectKey)
    }

    // MARK: Loading

    /// Reads `urls` off the main thread and merges the files in.
    /// - Parameters:
    ///   - states: saved on/off choices by path (otherwise bibliographies start off).
    ///   - removed: paths not to list again.
    private func load(_ urls: [URL], states: [String: Bool], removed: Set<String>, announce: Bool) {
        isLoading = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { Self.load(urls) }.value
            isLoading = false
            var added = 0
            for loaded in result.files {
                let path = loaded.url.standardizedFileURL.path
                guard !removed.contains(path) else { continue }
                if let i = items.firstIndex(where: { $0.origin == .file(loaded.url) }) {
                    items[i].text = loaded.text
                    items[i].modified = loaded.modified
                } else {
                    var item = Item(name: loaded.name, text: loaded.text, origin: .file(loaded.url), modified: loaded.modified)
                    // Bibliographies are long and rarely help a rewrite; opt in.
                    item.isEnabled = states[path] ?? (loaded.url.pathExtension.lowercased() != "bib")
                    items.append(item)
                    added += 1
                }
            }
            if announce {
                var notes: [String] = []
                if !result.files.isEmpty { notes.append("Added \(result.files.count) file\(result.files.count == 1 ? "" : "s").") }
                if result.skipped > 0 { notes.append("Skipped \(result.skipped) that weren’t text or were too large.") }
                if result.files.isEmpty && result.skipped == 0 { notes.append("No text files found.") }
                if projectFolder != nil { notes.append("They’ll be attached again whenever you open a file from this folder.") }
                lastMessage = notes.joined(separator: " ")
                persist()
            } else if added > 0 {
                lastMessage = "Restored \(added) reference document\(added == 1 ? "" : "s") saved for this folder."
            }
        }
    }

    // MARK: Saved sessions

    /// The attached references for a saved session, with a copy of each text
    /// under `folder` in the package.
    func sessionState(folder: String, bookmarks: BookmarkCache) -> (references: [SessionManifest.ReferenceState], texts: [String: String]) {
        var references: [SessionManifest.ReferenceState] = []
        var texts: [String: String] = [:]
        for item in attachedItems {
            let path = "\(folder)/\(item.id.uuidString).txt"
            texts[path] = item.text
            switch item.origin {
            case .file(let url):
                references.append(.init(id: item.id, name: item.name, kind: .file, isEnabled: item.isEnabled, textFile: path,
                                        filePath: url.path, fileBookmark: bookmarks.data(for: url), modified: item.modified))
            case .pasted:
                references.append(.init(id: item.id, name: item.name, kind: .pasted, isEnabled: item.isEnabled, textFile: path))
            case .tab:
                continue
            }
        }
        return (references, texts)
    }

    /// Replaces the attached references with a saved session's. Files are
    /// read again when they've changed (before each request); until then, and
    /// wherever the file can't be reached, the saved copy is used.
    func restore(_ references: [SessionManifest.ReferenceState], texts: [String: String], bookmarks: BookmarkCache) {
        followsProjectFolder = false
        projectKey = nil
        sources.removeAll()
        removedPaths.removeAll()
        items.removeAll { !$0.isTab }
        for reference in references {
            let text = texts[reference.textFile] ?? ""
            switch reference.kind {
            case .pasted:
                items.append(Item(id: reference.id, name: reference.name, text: text, origin: .pasted, isEnabled: reference.isEnabled))
            case .file:
                guard let url = bookmarks.resolve(reference.fileBookmark, path: reference.filePath) else { continue }
                if reference.fileBookmark != nil, !accessed.contains(url), url.startAccessingSecurityScopedResource() { accessed.append(url) }
                items.append(Item(id: reference.id, name: reference.name, text: text, origin: .file(url),
                                  isEnabled: reference.isEnabled, modified: reference.modified))
            }
        }
    }

    nonisolated static func bookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    nonisolated static func resolve(_ data: Data) -> URL? {
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) { return url }
        return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    // MARK: Loading files

    struct LoadedFile: Sendable {
        var url: URL
        var name: String
        var text: String
        var modified: Date?
    }

    nonisolated static func load(_ urls: [URL]) -> (files: [LoadedFile], skipped: Int) {
        var files: [LoadedFile] = []
        var skipped = 0
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]

        func read(_ url: URL, name: String) {
            guard files.count < maxFiles else { skipped += 1; return }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if let size = values?.fileSize, size > maxFileSize { skipped += 1; return }
            guard let text = try? DiffDocument.readText(url) else { skipped += 1; return }
            files.append(LoadedFile(url: url, name: name, text: text, modified: values?.contentModificationDate))
        }

        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else { read(url, name: url.lastPathComponent); continue }
            guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            var found: [URL] = []
            for case let file as URL in enumerator {
                let values = try? file.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    if skippedFolders.contains(file.lastPathComponent) { enumerator.skipDescendants() }
                    continue
                }
                guard values?.isRegularFile == true, folderExtensions.contains(file.pathExtension.lowercased()) else { continue }
                found.append(file)
            }
            // Natural order, so 2_background.tex comes before 10_appendix.tex.
            found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let base = url.standardizedFileURL.path
            for file in found {
                var relative = file.standardizedFileURL.path
                if relative.hasPrefix(base) { relative = String(relative.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
                read(file, name: relative.isEmpty ? file.lastPathComponent : relative)
            }
        }
        return (files, skipped)
    }
}

extension DiffDocument.Side {
    var other: DiffDocument.Side { self == .left ? .right : .left }
}

// MARK: - Saved references

/// Reference documents saved per project folder, in the app's support folder.
struct ReferenceStore {
    struct Pasted: Codable, Equatable {
        var id: UUID
        var name: String
        var text: String
        var isEnabled: Bool
    }

    struct Project: Codable, Equatable {
        /// Security-scoped bookmarks of the files and folders the user added.
        var sources: [Data]
        /// On/off choices by file path.
        var states: [String: Bool]
        /// Files the user removed from an added folder, by path.
        var removed: [String]
        var pasted: [Pasted]
        var saved: Date

        var isEmpty: Bool { sources.isEmpty && pasted.isEmpty }
    }

    let url: URL

    static let shared: ReferenceStore = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return ReferenceStore(url: support.appendingPathComponent("Diffactly/References.json"))
    }()

    /// Most projects kept; the least recently saved go first.
    static let projectLimit = 60

    func all() -> [String: Project] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Project].self, from: data)) ?? [:]
    }

    /// What's saved for `folder`, or for the nearest folder that contains it.
    func project(for folder: URL) -> (key: String, project: Project)? {
        let projects = all()
        var path = folder.standardizedFileURL.path
        while true {
            if let project = projects[path] { return (path, project) }
            let parent = (path as NSString).deletingLastPathComponent
            guard parent != path, !parent.isEmpty, parent != "/" else { return nil }
            path = parent
        }
    }

    func save(_ project: Project?, key: String) {
        var projects = all()
        projects[key] = project
        if projects.count > Self.projectLimit {
            for (old, _) in projects.sorted(by: { $0.value.saved < $1.value.saved }).prefix(projects.count - Self.projectLimit) {
                projects[old] = nil
            }
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(projects).write(to: url, options: .atomic)
        } catch {
            // Losing the saved list only means re-attaching the files later.
        }
    }
}
