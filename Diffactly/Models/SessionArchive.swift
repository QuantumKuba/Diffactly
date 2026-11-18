import Foundation
import UniformTypeIdentifiers
import DiffactlyCore

// A saved session is a `.diffactly` package (a folder Finder shows as one
// file) wherever the user chose to keep it:
//
//   Thesis.diffactly/
//     Session.json                      tabs, settings, comments, AI versions…
//     Tabs/<tab id>/left.tex            each tab's texts, as plain files
//     Tabs/<tab id>/right.tex
//     Tabs/<tab id>/References/<id>.txt attached reference documents
//
// The texts are ordinary files so they can be read, synced or versioned
// without Diffactly; everything else is in the (pretty-printed) manifest.

extension UTType {
    /// A saved Diffactly session (declared in Info.plist).
    static let diffactlySession = UTType(exportedAs: "com.diffactly.session", conformingTo: .package)
}

// MARK: - Manifest

/// `Session.json`: everything about a session except the texts themselves,
/// which it refers to by their paths inside the package.
struct SessionManifest: Codable, Equatable {
    /// Bumped when the format changes in a way older versions can't read.
    static let currentFormat = 1

    var format = SessionManifest.currentFormat
    /// The Diffactly version that wrote it.
    var app: String?
    /// The tab that was selected.
    var activeTab: UUID?
    var tabs: [Tab]

    /// One tab (comparison window).
    struct Tab: Codable, Equatable {
        var id: UUID
        /// The custom tab name ("" names it after the open files).
        var title: String
        var left: SideState
        var right: SideState
        var view: ViewState
        var comments: [CommentState]
        var highlights: [HighlightState]
        var suggestions: [SuggestionState]
        var ai: AIState?
        var references: [ReferenceState]
        /// Passages AI rewrites were accepted into (absent in older sessions).
        var acceptedRewrites: [AcceptedRewriteState]? = nil
        /// Passages paired across the sides (absent in older sessions).
        var links: [LinkState]? = nil
    }

    struct SideState: Codable, Equatable {
        /// The pane's title ("Original", "Draft", …).
        var title: String
        /// Where the text is, inside the package.
        var textFile: String
        /// The file the text was opened from, if any.
        var fileName: String?
        var filePath: String?
        var fileBookmark: Data?
    }

    struct ViewState: Codable, Equatable {
        var mode: DiffDocument.Mode
        var options: DiffOptions
        var collapseUnchanged: Bool
        var wrapLines: Bool
        var showInsights: Bool
        var showsResolvedComments: Bool
        var showsComments: Bool
    }

    struct CommentState: Codable, Equatable {
        var id: UUID
        var side: DiffDocument.Side
        var location: Int
        var length: Int
        var quote: String
        var originalQuote: String
        var body: String
        var isResolved: Bool
        var isDetached: Bool
        var created: Date
        var edited: Date
    }

    /// Text highlighted as a source for AI rewrites.
    struct HighlightState: Codable, Equatable {
        var side: DiffDocument.Side
        var location: Int
        var length: Int
        var text: String
    }

    /// A passage with accepted AI rewrites, and what it said before each.
    struct AcceptedRewriteState: Codable, Equatable {
        struct Step: Codable, Equatable {
            var original: String
            var rewrite: String
            var label: String
            var date: Date
            var suggestion: SuggestionState?
        }
        var side: DiffDocument.Side
        var location: Int
        var length: Int
        var text: String
        var steps: [Step]
    }

    struct LinkState: Codable, Equatable {
        var leftLocation: Int
        var leftLength: Int
        var leftText: String
        var rightLocation: Int
        var rightLength: Int
        var rightText: String
        var isAutomatic: Bool
    }

    /// An inline AI suggestion waiting for review, with all its versions.
    struct SuggestionState: Codable, Equatable {
        var side: DiffDocument.Side
        var location: Int
        var length: Int
        var original: String
        var isStale: Bool
        /// Index into `versions` of the one on show.
        var shownVersion: Int
        var versions: [VersionState]
    }

    struct VersionState: Codable, Equatable {
        var text: String
        var label: String
        var basisLabel: String?
        var date: Date
        var duration: TimeInterval?
        var didAudit: Bool
        var truncation: RewriteTruncation?
        /// Parts of this version rewritten on their own (absent in older sessions).
        var refinements: [RefinementState]? = nil
    }

    /// A part of a suggestion's version rewritten on its own, with its versions.
    struct RefinementState: Codable, Equatable {
        /// Where the part is in the version's text (UTF-16).
        var location: Int
        var length: Int
        var original: String
        /// Index into `versions` of the one on show; nil when the version's
        /// own wording is used instead.
        var shownVersion: Int?
        var versions: [VersionState]
    }

    /// The AI sheet: its choices and every result (the V1, V2, … history).
    struct AIState: Codable, Equatable {
        var task: AITask
        var source: RewriteSource
        var leftWeight: Double
        var strength: RewriteStrength
        var promptID: String
        var providerID: UUID?
        var avoidAITells: Bool
        var academicVoice: Bool
        var secondPass: SecondPassMode
        var preserveFormatting: Bool
        var useCustomTemperature: Bool
        var temperature: Double
        var summaryDetail: SummaryDetail
        var summaryFocus: SummaryFocus
        var includeOtherSide: Bool
        var passageWeight: Double
        var extraNotes: String
        /// Newest first.
        var history: [ResultState]
        var shownRewrite: UUID?
        var shownSummary: UUID?
    }

    struct ResultState: Codable, Equatable {
        var id: UUID
        var task: AITask
        var text: String
        var label: String
        var date: Date
        var passage: PassageState?
        var sourceText: String
        var subject: SubjectState
        var duration: TimeInterval?
        var didAudit: Bool
        var truncation: RewriteTruncation?
        var outputBudget: Int
    }

    struct PassageState: Codable, Equatable {
        var side: DiffDocument.Side
        var location: Int
        var length: Int
        var text: String
    }

    /// What a result was made from (results of one subject are its versions).
    struct SubjectState: Codable, Equatable {
        enum Kind: String, Codable { case text, passage, summary }
        var kind: Kind
        var source: RewriteSource?
        var side: DiffDocument.Side?
        var text: String?
    }

    /// A reference document the user attached.
    struct ReferenceState: Codable, Equatable {
        enum Kind: String, Codable { case file, pasted }
        var id: UUID
        var name: String
        var kind: Kind
        var isEnabled: Bool
        /// A copy of its text, inside the package (so the session works even
        /// where the original file isn't).
        var textFile: String
        var filePath: String?
        var fileBookmark: Data?
        var modified: Date?
    }

    /// Every text file the manifest refers to: the tabs' texts, then the references'.
    var textFiles: [String] {
        tabs.flatMap { [$0.left.textFile, $0.right.textFile] } + tabs.flatMap { $0.references.map(\.textFile) }
    }
}

extension AITask: Codable {}
extension SecondPassMode: Codable {}
extension DiffDocument.Mode: Codable {}
extension DiffDocument.Side: Codable {}
extension RewriteTruncation: Codable {}

// MARK: - Package

/// A session as it is on disk: the manifest plus the text files it refers to.
struct SessionPackage: Equatable {
    var manifest: SessionManifest
    /// File contents by path inside the package.
    var texts: [String: String]

    static let manifestName = "Session.json"
    static let tabsFolder = "Tabs"

    enum Failure: LocalizedError {
        case notASession(String)
        case newerFormat(String)
        case damaged(String, String)
        case missingText(String, String)

        var errorDescription: String? {
            switch self {
            case .notASession(let name): return "“\(name)” isn’t a Diffactly session."
            case .newerFormat(let name): return "“\(name)” was saved by a newer version of Diffactly. Update Diffactly to open it."
            case .damaged(let name, let reason): return "“\(name)” is damaged and can’t be opened (\(reason))."
            case .missingText(let name, let path): return "“\(name)” is missing one of its texts (\(path))."
            }
        }
    }

    // MARK: Reading

    static func read(from url: URL) throws -> SessionPackage {
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url.appendingPathComponent(manifestName)) else { throw Failure.notASession(name) }
        struct Header: Decodable { var format: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { throw Failure.notASession(name) }
        guard header.format <= SessionManifest.currentFormat else { throw Failure.newerFormat(name) }
        let manifest: SessionManifest
        do {
            manifest = try decoder.decode(SessionManifest.self, from: data)
        } catch {
            throw Failure.damaged(name, Self.describe(error))
        }
        var texts: [String: String] = [:]
        let tabTexts = Set(manifest.tabs.flatMap { [$0.left.textFile, $0.right.textFile] })
        for path in manifest.textFiles where texts[path] == nil {
            guard isSafe(path) else { throw Failure.damaged(name, "a text is stored outside the session") }
            let file = url.appendingPathComponent(path)
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                texts[path] = text
            } else if let data = try? Data(contentsOf: file) {
                texts[path] = String(decoding: data, as: UTF8.self)
            } else if tabTexts.contains(path) {
                throw Failure.missingText(name, path)
            } else {
                // A reference's copy is only a fallback for its file.
                texts[path] = ""
            }
        }
        return SessionPackage(manifest: manifest, texts: texts)
    }

    private static func describe(_ error: Error) -> String {
        if case DecodingError.keyNotFound(let key, _) = error { return "no “\(key.stringValue)”" }
        if case DecodingError.dataCorrupted(let context) = error { return context.debugDescription }
        return "unreadable Session.json"
    }

    /// A relative path that stays inside the package.
    static func isSafe(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }

    // MARK: Writing

    /// Writes the session to `url`, creating the package if needed. Only
    /// texts that differ from `previous` (what was last written there) are
    /// rewritten, and files the session no longer uses are removed.
    func write(to url: URL, previous: SessionPackage? = nil) throws {
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue {
            try fm.removeItem(at: url)
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        for (path, text) in texts {
            precondition(Self.isSafe(path))
            let file = url.appendingPathComponent(path)
            if previous?.texts[path] == text, fm.fileExists(atPath: file.path) { continue }
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file, options: .atomic)
        }
        // Last, so the manifest never refers to a text that isn't there yet.
        try Self.encoder.encode(manifest).write(to: url.appendingPathComponent(Self.manifestName), options: .atomic)
        removeUnusedFiles(in: url)
    }

    /// Deletes texts of tabs and references that are gone (only under Tabs/).
    private func removeUnusedFiles(in url: URL) {
        let fm = FileManager.default
        let base = url.resolvingSymlinksInPath().path + "/"
        let tabs = url.appendingPathComponent(Self.tabsFolder)
        guard let enumerator = fm.enumerator(at: tabs, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        var folders: [URL] = []
        for case let file as URL in enumerator {
            if (try? file.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                folders.append(file)
                continue
            }
            let path = file.resolvingSymlinksInPath().path
            guard path.hasPrefix(base) else { continue }
            if texts[String(path.dropFirst(base.count))] == nil { try? fm.removeItem(at: file) }
        }
        // Deepest first, so a folder emptied by removing its subfolders goes too.
        for folder in folders.sorted(by: { $0.path.count > $1.path.count }) {
            if (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try? fm.removeItem(at: folder) }
        }
    }

    // MARK: Coding

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter.string(from: date))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = dateFormatter.date(from: string) ?? ISO8601DateFormatter().date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "bad date “\(string)”")
        }
        return decoder
    }()
}

// MARK: - Bookmarks

/// Bookmarks of the files a session refers to, made once per file: making a
/// new one on every autosave would change the manifest each time.
@MainActor
final class BookmarkCache {
    static let shared = BookmarkCache()
    private var cache: [String: Data?] = [:]

    func data(for url: URL) -> Data? {
        let key = url.standardizedFileURL.path
        if let cached = cache[key] { return cached }
        let data = ReferenceLibrary.bookmark(for: url)
        cache[key] = data
        return data
    }

    /// The file a saved bookmark (or, failing that, path) points at.
    func resolve(_ data: Data?, path: String?) -> URL? {
        if let data, let url = ReferenceLibrary.resolve(data) {
            cache[url.standardizedFileURL.path] = data
            return url
        }
        return path.map { URL(fileURLWithPath: $0) }
    }
}
