import Foundation
import AppKit
import DiffactlyCore

/// The supplementary documents attached to one window's AI session, such as
/// the other `.tex` files of the paper being edited. They're sent as
/// background with every rewrite and summary while enabled.
@MainActor
final class ReferenceLibrary: ObservableObject {

    struct Item: Identifiable, Equatable {
        enum Origin: Equatable {
            case file(URL)
            /// Another open comparison tab (followed live while it stays open).
            case tab(ObjectIdentifier, DiffDocument.Side)
            case pasted
        }

        let id = UUID()
        var name: String
        var text: String
        var origin: Origin
        var isEnabled = true
        var modified: Date?

        var fileName: String? {
            if case .file(let url) = origin { return url.lastPathComponent }
            return nil
        }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isLoading = false
    @Published var lastMessage: String?

    /// Prose-like files picked up when a whole folder is added.
    nonisolated static let folderExtensions: Set<String> = ["tex", "ltx", "bib", "md", "markdown", "mdx", "txt", "text", "rst", "org", "typ", "adoc", "asciidoc"]
    /// Folders that hold build output rather than sources.
    nonisolated static let skippedFolders: Set<String> = ["node_modules", "build", "out", "dist", "_minted", "__pycache__", "venv", ".venv"]
    nonisolated static let maxFileSize = 2_000_000
    nonisolated static let maxFiles = 400

    // MARK: Reading

    /// Enabled documents, minus any file that is already open in this window
    /// (it's in the prompt anyway, possibly in a newer version).
    func documents(excludingFileNames open: Set<String>) -> [ReferenceDocument] {
        items.filter { $0.isEnabled && !isOpen($0, open) }
            .map { ReferenceDocument(name: $0.name, text: $0.text) }
    }

    func isOpen(_ item: Item, _ open: Set<String>) -> Bool {
        guard let name = item.fileName else { return false }
        return open.contains(name)
    }

    func characterCount(excludingFileNames open: Set<String>) -> Int {
        items.reduce(0) { $0 + ($1.isEnabled && !isOpen($1, open) ? $1.text.count : 0) }
    }

    var hasEnabledItems: Bool { items.contains(where: \.isEnabled) }

    // MARK: Editing the list

    func setEnabled(_ enabled: Bool, id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].isEnabled = enabled
    }

    func remove(id: UUID) { items.removeAll { $0.id == id } }

    func removeAll() { items.removeAll() }

    func addFromPasteboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastMessage = "The clipboard has no text."
            return
        }
        let number = items.filter { $0.origin == .pasted }.count + 1
        items.append(Item(name: "Pasted text \(number)", text: text, origin: .pasted))
    }

    func addTab(_ document: DiffDocument, side: DiffDocument.Side) {
        let origin = Item.Origin.tab(ObjectIdentifier(document), side)
        let name = (side == .left ? document.leftName : document.rightName)
            ?? "\(document.displayTabTitle) · \(document.title(for: side))"
        if let i = items.firstIndex(where: { $0.origin == origin }) {
            items[i].text = document.text(for: side)
        } else {
            items.append(Item(name: name, text: document.text(for: side), origin: origin))
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
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    /// Adds files, and the prose files inside folders (recursively).
    func add(_ urls: [URL]) {
        isLoading = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { Self.load(urls) }.value
            isLoading = false
            for loaded in result.files {
                if let i = items.firstIndex(where: { $0.origin == .file(loaded.url) }) {
                    items[i].text = loaded.text
                    items[i].modified = loaded.modified
                } else {
                    var item = Item(name: loaded.name, text: loaded.text, origin: .file(loaded.url), modified: loaded.modified)
                    // Bibliographies are long and rarely help a rewrite; opt in.
                    item.isEnabled = loaded.url.pathExtension.lowercased() != "bib"
                    items.append(item)
                }
            }
            var notes: [String] = []
            if !result.files.isEmpty { notes.append("Added \(result.files.count) file\(result.files.count == 1 ? "" : "s").") }
            if result.skipped > 0 { notes.append("Skipped \(result.skipped) that weren’t text or were too large.") }
            if result.files.isEmpty && result.skipped == 0 { notes.append("No text files found.") }
            lastMessage = notes.joined(separator: " ")
        }
    }

    /// Re-reads files changed on disk and pulls the current text of linked
    /// tabs, so a request always sees the latest versions.
    func refresh() {
        for i in items.indices {
            switch items[i].origin {
            case .file(let url):
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard modified != items[i].modified, let text = try? DiffDocument.readText(url) else { continue }
                items[i].text = text
                items[i].modified = modified
            case .tab(let id, let side):
                if let document = DocumentRouter.shared.document(id), document.text(for: side) != items[i].text {
                    items[i].text = document.text(for: side)
                }
            case .pasted:
                continue
            }
        }
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
