import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DiffactlyCore
import Combine

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
        var defaultTitle: String { self == .left ? "Original" : "Changed" }
        var title: String { defaultTitle }
    }

    /// Asks the editors (or the output view) to bring a change into view.
    struct FocusRequest: Equatable {
        let id = UUID()
        var hunk: Int
        var leftLines: ClosedRange<Int>?
        var rightLines: ClosedRange<Int>?
        var rowID: Int
    }

    /// Totals for the text currently selected in an editor.
    struct SelectionCounts: Equatable {
        var side: Side
        var counts: TextCounts
        var text: String = ""
    }

    // MARK: Inputs

    @Published var leftText: String { didSet { if leftText != oldValue { leftCounts = TextCounts(leftText); scheduleDiff(); search.performSearch() } } }
    @Published var rightText: String { didSet { if rightText != oldValue { rightCounts = TextCounts(rightText); scheduleDiff(); search.performSearch() } } }
    @Published var leftName: String?
    @Published var rightName: String?
    @Published var leftTitle: String = "Original"
    @Published var rightTitle: String = "Changed"

    // MARK: Settings (persisted)

    @Published var options: DiffOptions {
        didSet {
            guard options != oldValue else { return }
            Self.save(options)
            scheduleDiff(immediately: true)
        }
    }
    @Published var mode: Mode {
        didSet {
            defaults.set(mode.rawValue, forKey: Keys.mode)
            // Only the editors report selections; leaving them drops a stale one.
            if mode != .edit { selection = nil }
        }
    }
    @Published var collapseUnchanged: Bool { didSet { defaults.set(collapseUnchanged, forKey: Keys.collapse); expandedFolds.removeAll() } }
    @Published var wrapLines: Bool { didSet { defaults.set(wrapLines, forKey: Keys.wrap) } }
    @Published var showInsights: Bool { didSet { defaults.set(showInsights, forKey: Keys.insights) } }

    // MARK: Output

    @Published private(set) var result: DiffResult = .empty
    /// Word / character / line totals of each side, kept in sync with the text.
    @Published private(set) var leftCounts: TextCounts
    @Published private(set) var rightCounts: TextCounts
    /// What the user has selected in one of the editors (nil when nothing is).
    @Published private(set) var selection: SelectionCounts?
    @Published private(set) var wordShifts: [DiffInsights.WordShift] = []
    @Published private(set) var isComputing = false
    @Published private(set) var leftHighlights = EditorHighlights()
    @Published private(set) var rightHighlights = EditorHighlights()
    @Published private(set) var currentHunk: Int?
    @Published var focusRequest: FocusRequest?
    @Published var expandedFolds: Set<Int> = []
    @Published var errorMessage: String?
    @Published var search = SearchModel()

    private var diffTask: Task<Void, Never>?
    private var generation = 0
    private var searchCancellable: AnyCancellable?
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let options = "diffOptions"
        static let mode = "viewMode"
        static let collapse = "collapseUnchanged"
        static let wrap = "wrapLines"
        static let insights = "showInsights"
    }

    init(
        left: String = "This is some text on the left side",
        right: String = "This is some new text on the right side",
        leftTitle: String = "Original",
        rightTitle: String = "Changed"
    ) {
        let trimmedLeftTitle = leftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRightTitle = rightTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.leftTitle = trimmedLeftTitle.isEmpty ? "Original" : trimmedLeftTitle
        self.rightTitle = trimmedRightTitle.isEmpty ? "Changed" : trimmedRightTitle
        leftText = left
        rightText = right
        leftCounts = TextCounts(left)
        rightCounts = TextCounts(right)
        options = Self.loadOptions()
        mode = Mode(rawValue: UserDefaults.standard.string(forKey: Keys.mode) ?? "") ?? .edit
        collapseUnchanged = UserDefaults.standard.object(forKey: Keys.collapse) as? Bool ?? false
        wrapLines = UserDefaults.standard.object(forKey: Keys.wrap) as? Bool ?? true
        showInsights = UserDefaults.standard.bool(forKey: Keys.insights)
        search.document = self
        searchCancellable = search.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
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
            self.search.updateRowIDs(with: computed.0)
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
        focus(lines: side == .left ? move.from : move.to, side: side)
    }

    /// Bring a line range on one side into view (move and relation jumps).
    func focus(lines: ClosedRange<Int>, side: Side) {
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
        let (lt, rt) = (leftTitle, rightTitle)
        leftText = r; rightText = l
        leftName = rn; rightName = ln
        leftTitle = rt; rightTitle = lt
        if search.scope == .left {
            search.scope = .right
        } else if search.scope == .right {
            search.scope = .left
        }
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

    func title(for side: Side) -> String {
        let raw = side == .left ? leftTitle : rightTitle
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? side.defaultTitle : trimmed
    }

    func setTitle(_ title: String, for side: Side) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? side.defaultTitle : trimmed
        if side == .left {
            leftTitle = resolved
        } else {
            rightTitle = resolved
        }
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

    /// Called by an editor whenever its selection changes. An empty selection
    /// only clears the state if that same side owned it, so the other editor's
    /// selection isn't wiped by a click here.
    func updateSelection(side: Side, selectedText: String) {
        if selectedText.isEmpty {
            if selection?.side == side { selection = nil }
        } else {
            let next = SelectionCounts(side: side, counts: TextCounts(selectedText), text: selectedText)
            if selection != next { selection = next }
        }
        activeSide = side
    }

    // MARK: - Search helpers

    var activeSide: Side? {
        get { search.activeSide }
        set { search.activeSide = newValue }
    }

    func openSearch(focusedSide: Side? = nil) { search.openSearch(focusedSide: focusedSide) }
    func closeSearch() { search.closeSearch() }
    func findNext() { search.findNext() }
    func findPrevious() { search.findPrevious() }
    func useSelectionForSearch() { search.useSelectionForSearch() }

    func showOpenPanel(for side: Side) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let label = title(for: side)
        panel.message = "Choose the \(label.lowercased()) file"
        panel.prompt = "Open \(label)"
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
        UnifiedFormatter.patch(
            result,
            leftLabel: leftName.map { "a/\($0)" } ?? title(for: .left).lowercased(),
            rightLabel: rightName.map { "b/\($0)" } ?? title(for: .right).lowercased()
        )
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
