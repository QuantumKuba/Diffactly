import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DiffactlyCore

/// State of one Diffactly window: the two texts, the comparison settings and the
/// latest result. Diffs run off the main thread and are debounced while typing.
@MainActor
final class DiffDocument: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case edit, split, unified
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var systemImage: String {
            switch self {
            case .edit: return "square.and.pencil"
            case .split: return "rectangle.split.2x1"
            case .unified: return "rectangle.split.1x2"
            }
        }
    }

    enum Side: Hashable {
        case left, right
        var title: String { self == .left ? "Original" : "Changed" }
    }

    /// Asks the editors (or the output view) to bring a change into view.
    struct FocusRequest: Equatable {
        let id = UUID()
        var hunk: Int
        var leftLines: ClosedRange<Int>?
        var rightLines: ClosedRange<Int>?
        var rowID: Int
    }

    // MARK: Inputs

    @Published var leftText: String { didSet { if leftText != oldValue { scheduleDiff() } } }
    @Published var rightText: String { didSet { if rightText != oldValue { scheduleDiff() } } }
    @Published var leftName: String?
    @Published var rightName: String?

    // MARK: Settings (persisted)

    @Published var options: DiffOptions {
        didSet {
            guard options != oldValue else { return }
            Self.save(options)
            scheduleDiff(immediately: true)
        }
    }
    @Published var mode: Mode { didSet { defaults.set(mode.rawValue, forKey: Keys.mode) } }
    @Published var collapseUnchanged: Bool { didSet { defaults.set(collapseUnchanged, forKey: Keys.collapse); expandedFolds.removeAll() } }
    @Published var wrapLines: Bool { didSet { defaults.set(wrapLines, forKey: Keys.wrap) } }
    @Published var showInsights: Bool { didSet { defaults.set(showInsights, forKey: Keys.insights) } }

    // MARK: Output

    @Published private(set) var result: DiffResult = .empty
    @Published private(set) var wordShifts: [DiffInsights.WordShift] = []
    @Published private(set) var isComputing = false
    @Published private(set) var leftHighlights = EditorHighlights()
    @Published private(set) var rightHighlights = EditorHighlights()
    @Published private(set) var currentHunk: Int?
    @Published var focusRequest: FocusRequest?
    @Published var expandedFolds: Set<Int> = []
    @Published var errorMessage: String?

    private var diffTask: Task<Void, Never>?
    private var generation = 0
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let options = "diffOptions"
        static let mode = "viewMode"
        static let collapse = "collapseUnchanged"
        static let wrap = "wrapLines"
        static let insights = "showInsights"
    }

    init(left: String = "This is some text on the left side", right: String = "This is some new text on the right side") {
        leftText = left
        rightText = right
        options = Self.loadOptions()
        mode = Mode(rawValue: UserDefaults.standard.string(forKey: Keys.mode) ?? "") ?? .edit
        collapseUnchanged = UserDefaults.standard.object(forKey: Keys.collapse) as? Bool ?? false
        wrapLines = UserDefaults.standard.object(forKey: Keys.wrap) as? Bool ?? true
        showInsights = UserDefaults.standard.bool(forKey: Keys.insights)
        scheduleDiff(immediately: true)
    }

    private static func loadOptions() -> DiffOptions {
        guard let data = UserDefaults.standard.data(forKey: Keys.options),
              let decoded = try? JSONDecoder().decode(DiffOptions.self, from: data) else { return DiffOptions() }
        return decoded
    }

    private static func save(_ options: DiffOptions) {
        if let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: Keys.options) }
    }

    // MARK: Diffing

    func scheduleDiff(immediately: Bool = false) {
        diffTask?.cancel()
        generation += 1
        let token = generation
        let left = leftText, right = rightText, options = options
        isComputing = true
        diffTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(nanoseconds: 120_000_000)
                if Task.isCancelled { return }
            }
            let computed = await Task.detached(priority: .userInitiated) { () -> (DiffResult, [DiffInsights.WordShift], EditorHighlights, EditorHighlights) in
                let result = DiffEngine.compare(left, right, options: options)
                let shifts = DiffInsights.wordShifts(left: left, right: right, limit: 8)
                return (result, shifts,
                        EditorHighlights(result: result, side: .left, text: left),
                        EditorHighlights(result: result, side: .right, text: right))
            }.value
            guard let self, !Task.isCancelled, token == self.generation else { return }
            self.result = computed.0
            self.wordShifts = computed.1
            self.leftHighlights = computed.2
            self.rightHighlights = computed.3
            self.isComputing = false
            if let current = self.currentHunk, current >= computed.0.hunks.count { self.currentHunk = nil }
        }
    }

    // MARK: Navigation

    var hasChanges: Bool { !result.hunks.isEmpty }

    func nextChange() { moveToHunk(offset: 1) }
    func previousChange() { moveToHunk(offset: -1) }

    func focus(hunk index: Int) {
        guard result.hunks.indices.contains(index) else { return }
        currentHunk = index
        let h = result.hunks[index]
        focusRequest = FocusRequest(hunk: index, leftLines: h.leftLines, rightLines: h.rightLines, rowID: h.rowRange.lowerBound)
    }

    /// Jump to the change containing (or nearest after) a row.
    func focus(row: Int) {
        guard let index = result.hunks.firstIndex(where: { $0.rowRange.upperBound > row }) ?? result.hunks.indices.last else { return }
        focus(hunk: index)
    }

    func focus(move: DiffMove, side: Side) {
        let lines = side == .left ? move.from : move.to
        let row = result.rows.first { side == .left ? $0.left?.number == lines.lowerBound : $0.right?.number == lines.lowerBound }
        focusRequest = FocusRequest(
            hunk: currentHunk ?? 0,
            leftLines: side == .left ? lines : nil,
            rightLines: side == .right ? lines : nil,
            rowID: row?.id ?? 0
        )
    }

    private func moveToHunk(offset: Int) {
        let count = result.hunks.count
        guard count > 0 else { return }
        let next: Int
        if let current = currentHunk { next = (current + offset + count) % count } else { next = offset > 0 ? 0 : count - 1 }
        focus(hunk: next)
    }

    // MARK: Editing actions

    func swapSides() {
        let (l, r) = (leftText, rightText)
        let (ln, rn) = (leftName, rightName)
        leftText = r; rightText = l
        leftName = rn; rightName = ln
    }

    func clear(_ side: Side) {
        if side == .left { leftText = ""; leftName = nil } else { rightText = ""; rightName = nil }
    }

    func apply(_ transform: TextTransform) {
        leftText = transform.apply(to: leftText)
        rightText = transform.apply(to: rightText)
    }

    func text(for side: Side) -> String { side == .left ? leftText : rightText }

    func setText(_ text: String, for side: Side) {
        if side == .left { leftText = text } else { rightText = text }
    }

    // MARK: Files

    func open(_ url: URL, into side: Side) {
        do {
            let text = try Self.readText(url)
            if side == .left { leftText = text; leftName = url.lastPathComponent } else { rightText = text; rightName = url.lastPathComponent }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Opens files handed to the app (Finder, `diffactly --gui`, drag onto the Dock icon).
    func open(_ urls: [URL]) {
        if urls.count >= 2 {
            open(urls[0], into: .left)
            open(urls[1], into: .right)
        } else if let url = urls.first {
            // Fill the original first; once both are files, replace the changed side.
            open(url, into: leftName == nil ? .left : .right)
        }
        if mode == .edit, urls.count >= 2 { mode = .split }
    }

    func showOpenPanel(for side: Side) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the \(side.title.lowercased()) file"
        panel.prompt = "Open \(side.title)"
        if panel.runModal() == .OK, let url = panel.url { open(url, into: side) }
    }

    struct NotTextError: LocalizedError {
        let name: String
        var errorDescription: String? { "“\(name)” doesn’t look like a text file. Diffactly compares text." }
    }

    nonisolated static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if data.prefix(8000).contains(0) { throw NotTextError(name: url.lastPathComponent) }
        if let s = String(data: data, encoding: .utf8) { return s }
        var encoding = String.Encoding.utf8
        if let s = try? String(contentsOf: url, usedEncoding: &encoding) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Export

    var unifiedPatch: String {
        UnifiedFormatter.patch(result, leftLabel: leftName.map { "a/\($0)" } ?? "original", rightLabel: rightName.map { "b/\($0)" } ?? "changed")
    }
}

// MARK: - Editor highlights

/// Highlight ranges (UTF-16, matching NSTextView) for one editor.
struct EditorHighlights: Equatable, Sendable {
    enum Style: Equatable, Sendable { case removed, added, modified, moved }

    struct LineMark: Equatable, Sendable {
        var line: Int          // 1-based
        var range: NSRange     // whole line, without the newline
        var style: Style
    }

    var lines: [LineMark] = []
    var words: [(range: NSRange, style: Style)] = []
    /// The text these ranges were computed for; stale highlights are skipped.
    var text: String = ""

    static func == (a: EditorHighlights, b: EditorHighlights) -> Bool {
        a.text == b.text && a.lines == b.lines && a.words.count == b.words.count
            && zip(a.words, b.words).allSatisfy { $0.range == $1.range && $0.style == $1.style }
    }

    init() {}

    init(result: DiffResult, side: DiffDocument.Side, text: String) {
        self.text = text
        // UTF-16 offset of the start of every line.
        var starts: [Int] = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 10 { starts.append(offset) }
        }
        for row in result.rows where row.isChange {
            guard let line = side == .left ? row.left : row.right, line.number - 1 < starts.count else { continue }
            let start = starts[line.number - 1]
            let length = line.text.utf16.count
            let style: Style
            switch row.kind {
            case .modified: style = .modified
            case .removed: style = row.moveID != nil ? .moved : .removed
            case .added: style = row.moveID != nil ? .moved : .added
            case .unchanged: continue
            }
            lines.append(LineMark(line: line.number, range: NSRange(location: start, length: length), style: style))
            guard row.kind == .modified || row.moveID != nil else { continue }
            var cursor = start
            for seg in line.segments {
                let len = seg.text.utf16.count
                if seg.isChanged { words.append((NSRange(location: cursor, length: len), row.moveID != nil ? .moved : (side == .left ? .removed : .added))) }
                cursor += len
            }
        }
    }
}
