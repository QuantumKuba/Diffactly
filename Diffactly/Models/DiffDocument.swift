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

    enum Side: String, Hashable {
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
        /// UTF-16 range in that side's text (NSNotFound when unknown).
        var range = NSRange(location: NSNotFound, length: 0)
    }

    /// Asks an editor to select (and reveal) a range, e.g. a rewritten passage.
    struct SelectionRequest: Equatable {
        let id = UUID()
        var side: Side
        var range: NSRange
    }

    // MARK: Inputs

    @Published var leftText: String { didSet { if leftText != oldValue { leftCounts = TextCounts(leftText); textChanged(.left, from: oldValue) } } }
    @Published var rightText: String { didSet { if rightText != oldValue { rightCounts = TextCounts(rightText); textChanged(.right, from: oldValue) } } }
    @Published var leftName: String?
    @Published var rightName: String?
    /// Where each side was opened from (nil for pasted or typed text).
    @Published private(set) var leftURL: URL?
    @Published private(set) var rightURL: URL?
    @Published var leftTitle: String = "Original"
    @Published var rightTitle: String = "Changed"
    /// Custom name of this window's tab; empty means "name it automatically".
    @Published var tabTitle: String = ""
    /// Drives the "Rename Tab…" sheet.
    @Published var isRenamingTab = false
    /// Drives the AI sheet; `aiTask` picks which tab it opens on and
    /// `aiStartsWithSelection` whether it rewrites just the selected passage.
    @Published var isShowingAI = false
    @Published var aiTask: AITask = .rewrite
    @Published var aiStartsWithSelection = false

    func showAI(_ task: AITask, selection: Bool = false) {
        aiTask = task
        aiStartsWithSelection = selection && self.selection != nil
        isShowingAI = true
    }

    // MARK: AI suggestions

    /// Pending AI rewrites of passages, in the order they were asked for.
    @Published private(set) var suggestions: [AISuggestion] = []
    /// The suggestion whose card is open.
    @Published var presentedSuggestion: SuggestionPresentation?
    /// The suggestion being compared side by side with the current text.
    @Published var comparedSuggestion: AISuggestion?
    /// Starts an inline suggestion for a passage (set by the window, which
    /// owns the AI settings); the flag opens its settings first. Nil in
    /// documents without a window.
    var suggestionHandler: ((Side, NSRange, String, Bool) -> Void)?

    /// Text the user highlighted in either editor for passage rewrites to draw
    /// on (see SourceMarks.swift).
    @Published var sourceMarks: [SourceMark] = []

    /// Passages AI rewrites were accepted into, with what they said before
    /// (see RewriteHistory.swift).
    @Published var acceptedRewrites: [AcceptedRewrite] = []

    /// Passages paired across the two sides (see PassageLinks.swift).
    @Published var links: [PassageLink] = []
    /// One end of a link being made, waiting for the other.
    @Published var pendingLink: PendingLinkEnd?
    /// The link under the pointer, painted stronger on both sides.
    @Published var hoveredLinkID: UUID?

    // MARK: Comments (see TextComment.swift)

    /// Notes pinned to passages in either editor, in the order they were added.
    @Published var comments: [TextComment] = []
    /// The comment whose popover is open.
    @Published var presentedComment: CommentPresentation?
    /// Paint resolved comments in the editors too (they're always listed).
    @Published var showsResolvedComments = false
    /// Drives the comments sidebar.
    @Published var isShowingComments = false
    /// The comment last shown, where next / previous continue from.
    var currentCommentID: UUID?
    /// Where comments on files are saved (nil: kept in this window only).
    var commentStore: CommentStore?
    var commentSaveTask: Task<Void, Never>?

    /// The project folder, used to remember reference documents: the folder of
    /// the original file, or of the changed one.
    var projectFolder: URL? { (leftURL ?? rightURL)?.deletingLastPathComponent().standardizedFileURL }

    // MARK: Saved session (see SessionController.swift)

    /// The saved session this tab belongs to (nil until it's saved in one).
    @Published var projectSession: ProjectSession?
    /// Identifies this tab inside its session.
    var sessionTabID = UUID()
    /// This window's AI sheet, whose choices and results are saved with the session.
    weak var rewriteSession: RewriteSession?
    /// Changes the published properties don't announce (a comment's text),
    /// so a session knows to save.
    let contentChanged = PassthroughSubject<Void, Never>()

    nonisolated static let sampleLeft = "This is some text on the left side"
    nonisolated static let sampleRight = "This is some new text on the right side"

    /// Nothing done in this window yet: a session can open into it instead
    /// of a new one.
    var isPristine: Bool {
        projectSession == nil && leftURL == nil && rightURL == nil
            && (leftText.isEmpty || leftText == Self.sampleLeft)
            && (rightText.isEmpty || rightText == Self.sampleRight)
            && comments.isEmpty && suggestions.isEmpty && sourceMarks.isEmpty
            && acceptedRewrites.isEmpty && links.isEmpty
            && tabTitle.isEmpty && rewriteSession?.hasWork != true
    }

    /// Puts back the file a side was opened from without reading it (the
    /// session has the text as it was being worked on).
    func restoreFile(_ url: URL?, name: String?, for side: Side) {
        if side == .left { leftURL = url; leftName = name } else { rightURL = url; rightName = name }
    }
    // MARK: Settings (persisted)

    @Published var options: DiffOptions {
        didSet {
            guard options != oldValue else { return }
            if persistsSettings { Self.save(options) }
            scheduleDiff(immediately: true)
        }
    }
    @Published var mode: Mode {
        didSet {
            if persistsSettings { defaults.set(mode.rawValue, forKey: Keys.mode) }
            // Only the editors report selections; leaving them drops a stale one.
            if mode != .edit {
                selection = nil
                presentedSuggestion = nil
                presentedComment = nil
            }
        }
    }
    @Published var collapseUnchanged: Bool {
        didSet {
            if persistsSettings { defaults.set(collapseUnchanged, forKey: Keys.collapse) }
            expandedFolds.removeAll()
        }
    }
    @Published var wrapLines: Bool { didSet { if persistsSettings { defaults.set(wrapLines, forKey: Keys.wrap) } } }
    @Published var showInsights: Bool { didSet { if persistsSettings { defaults.set(showInsights, forKey: Keys.insights) } } }

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
    /// AI-writing tells in each text (computed with the diff, off the main thread).
    @Published private(set) var leftTells = AITells.scan("")
    @Published private(set) var rightTells = AITells.scan("")
    @Published private(set) var currentHunk: Int?
    @Published var focusRequest: FocusRequest?
    @Published var selectionRequest: SelectionRequest?
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

    /// False for throwaway documents (such as a suggestion's side-by-side
    /// preview), whose view settings must not overwrite the user's.
    private let persistsSettings: Bool

    init(
        left: String = DiffDocument.sampleLeft,
        right: String = DiffDocument.sampleRight,
        leftTitle: String = "Original",
        rightTitle: String = "Changed",
        persistsSettings: Bool = true
    ) {
        self.persistsSettings = persistsSettings
        commentStore = persistsSettings ? .shared : nil
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
            let computed = await Task.detached(priority: .userInitiated) { () -> (DiffResult, [DiffInsights.WordShift], EditorHighlights, EditorHighlights, AITells.Report, AITells.Report) in
                let result = DiffEngine.compare(left, right, options: options)
                let shifts = DiffInsights.wordShifts(left: left, right: right, limit: 8)
                return (result, shifts,
                        EditorHighlights(result: result, side: .left, text: left),
                        EditorHighlights(result: result, side: .right, text: right),
                        AITells.scan(left), AITells.scan(right))
            }.value
            guard let self, !Task.isCancelled, token == self.generation else { return }
            self.result = computed.0
            self.wordShifts = computed.1
            self.leftHighlights = computed.2
            self.rightHighlights = computed.3
            if self.leftTells != computed.4 { self.leftTells = computed.4 }
            if self.rightTells != computed.5 { self.rightTells = computed.5 }
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
        let (lu, ru) = (leftURL, rightURL)
        let (lt, rt) = (leftTitle, rightTitle)
        // Suggestions travel with their text instead of being tracked through
        // what looks like a whole-text replacement.
        isSwapping = true
        leftText = r; rightText = l
        isSwapping = false
        for suggestion in suggestions { suggestion.side = suggestion.side.other }
        for i in sourceMarks.indices { sourceMarks[i].side = sourceMarks[i].side.other }
        for i in acceptedRewrites.indices { acceptedRewrites[i].side = acceptedRewrites[i].side.other }
        links = links.map { PassageLink(id: $0.id, left: $0.right, leftText: $0.rightText, right: $0.left, rightText: $0.leftText, isAutomatic: $0.isAutomatic) }
        pendingLink?.side = pendingLink?.side.other ?? .left
        swapCommentSides()
        leftName = rn; rightName = ln
        leftURL = ru; rightURL = lu
        leftTitle = rt; rightTitle = lt
        if search.scope == .left {
            search.scope = .right
        } else if search.scope == .right {
            search.scope = .left
        }
    }

    func clear(_ side: Side) {
        releaseComments(on: side)
        if side == .left { leftText = ""; leftName = nil; leftURL = nil } else { rightText = ""; rightName = nil; rightURL = nil }
    }

    func clearAll() {
        clear(.left)
        clear(.right)
    }

    /// The side ⌘K clears: the editor last focused, or the original.
    var sideToClear: Side { activeSide ?? .left }

    func isEmpty(_ side: Side) -> Bool { text(for: side).isEmpty && (side == .left ? leftName : rightName) == nil }

    // MARK: Tab title

    /// "a.txt ↔ b.txt" when files are open, nil otherwise.
    var fileSummary: String? {
        switch (leftName, rightName) {
        case let (l?, r?): return "\(l) ↔ \(r)"
        case let (l?, nil): return l
        case let (nil, r?): return r
        default: return nil
        }
    }

    /// What the window (and its tab) is called when the user hasn't renamed it.
    var automaticTabTitle: String { fileSummary ?? "Diffactly" }

    var displayTabTitle: String {
        let trimmed = tabTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? automaticTabTitle : trimmed
    }

    func setTabTitle(_ title: String) {
        tabTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func apply(_ transform: TextTransform) {
        leftText = transform.apply(to: leftText)
        rightText = transform.apply(to: rightText)
    }

    func text(for side: Side) -> String { side == .left ? leftText : rightText }

    func setText(_ text: String, for side: Side) {
        if side == .left { leftText = text } else { rightText = text }
    }

    /// Replaces part of one side (undoable in the editor, which only swaps the
    /// changed range) and selects the new text so it's easy to see.
    @discardableResult
    func replace(_ range: NSRange, in side: Side, with replacement: String) -> Bool {
        guard let updated = SelectionRewrite.replacing(range, in: text(for: side), with: replacement) else { return false }
        setText(updated, for: side)
        let inserted = NSRange(location: range.location, length: (replacement as NSString).length)
        selectionRequest = SelectionRequest(side: side, range: inserted)
        updateSelection(side: side, selectedText: replacement, range: inserted)
        return true
    }

    // MARK: Suggestions

    /// Called whenever a side's text changes.
    private func textChanged(_ side: Side, from old: String) {
        scheduleDiff()
        search.performSearch()
        if !isSwapping {
            trackSuggestions(on: side, from: old)
            trackSourceMarks(on: side, from: old)
            trackComments(on: side, from: old)
            trackAcceptedRewrites(on: side, from: old)
            trackLinks(on: side, from: old)
        }
    }

    private var isSwapping = false

    /// Moves each pending suggestion on `side` along with its passage. One
    /// whose passage was edited goes stale; one whose passage is gone (the
    /// text was cleared or replaced) is dropped.
    private func trackSuggestions(on side: Side, from old: String) {
        let affected = suggestions.filter { $0.side == side }
        guard !affected.isEmpty else { return }
        let new = text(for: side)
        var removed: Set<UUID> = []
        for suggestion in affected {
            switch TrackedRange.follow(suggestion.range, passage: suggestion.original, old: old, new: new) {
            case .intact(let range):
                suggestion.range = range
                // Undoing an edit brings the passage back.
                if suggestion.status == .stale {
                    suggestion.status = suggestion.isComplete ? .ready : .failed("The passage was edited while the model was writing. Rewrite it again.")
                }
            case .edited(let range):
                suggestion.range = range
                // One still in setup asked for nothing yet; it starts on the passage as it reads then.
                if suggestion.status != .stale, suggestion.status != .configuring {
                    suggestion.cancel()
                    suggestion.status = .stale
                }
            case .removed:
                removed.insert(suggestion.id)
            }
        }
        if !removed.isEmpty { removeSuggestions { removed.contains($0.id) } }
    }

    /// The tints for one editor.
    /// Accepted rewrites come first, so pending suggestions paint over them.
    func suggestionMarks(for side: Side) -> [SuggestionMark] {
        rewriteMarks(for: side) + suggestions.filter { $0.side == side }.map { s in
            let style: SuggestionMark.Style
            switch s.status {
            case .ready: style = s.isAcceptable ? .ready : .pending
            case .stale, .failed: style = .stale
            case .configuring, .drafting, .auditing: style = .pending
            }
            return SuggestionMark(id: s.id, range: s.range, style: style)
        }
    }

    /// The pending suggestion on `side` whose passage takes in all of `range`.
    func suggestion(enclosing range: NSRange, on side: Side) -> AISuggestion? {
        suggestions.first { $0.side == side && $0.range.location <= range.location && NSMaxRange(range) <= NSMaxRange($0.range) }
    }

    func suggestion(id: UUID?) -> AISuggestion? {
        guard let id else { return nil }
        return suggestions.first { $0.id == id }
    }

    /// Adds a suggestion, replacing any pending one for an overlapping passage,
    /// and opens its card.
    func addSuggestion(_ suggestion: AISuggestion, present: Bool = true) {
        removeSuggestions { $0.side == suggestion.side && NSIntersectionRange($0.range, suggestion.range).length > 0 }
        suggestions.append(suggestion)
        if present {
            if mode != .edit { mode = .edit }
            presentedSuggestion = SuggestionPresentation(id: suggestion.id, pinned: true)
        }
    }

    /// Opens (id) or closes (nil) a suggestion's card. Merely pointing at a
    /// passage (`pinned` false) never replaces or closes a card the user opened
    /// on purpose.
    func presentSuggestion(_ id: UUID?, pinned: Bool) {
        if let current = presentedSuggestion, current.pinned, !pinned, id != current.id { return }
        guard let id else { presentedSuggestion = nil; return }
        presentedSuggestion = SuggestionPresentation(id: id, pinned: pinned)
    }

    /// The user closed a card (clicked elsewhere or pressed Esc).
    func suggestionCardClosed(_ id: UUID) {
        if presentedSuggestion?.id == id { presentedSuggestion = nil }
        // A passage still in setup has nothing to keep once its card is dismissed.
        if suggestion(id: id)?.status == .configuring { removeSuggestions { $0.id == id } }
    }

    /// The model's progress changed the suggestion's status (repaints the tints).
    func suggestionStatusChanged() { objectWillChange.send() }

    /// Swaps the passage for the suggestion as one undoable edit and selects
    /// the new text. Returns false when there's nothing to accept.
    @discardableResult
    func acceptSuggestion(_ id: UUID) -> Bool {
        guard let suggestion = suggestion(id: id), suggestion.isAcceptable else { return false }
        let current = text(for: suggestion.side) as NSString
        guard NSMaxRange(suggestion.range) <= current.length, current.substring(with: suggestion.range) == suggestion.original else {
            suggestion.status = .stale
            return false
        }
        // What the passage matches on the other side, while its words still line up.
        let counterpart = RewriteSession.counterpart(side: suggestion.side, range: suggestion.range, in: self)
        let saved = Self.suggestionState(suggestion)
        let replacement = suggestion.fittedReplacement
        // Take it (and any history inside the passage) off the lists first so
        // the edit isn't tracked as a change to them.
        removeSuggestions { $0.id == id }
        let earlier = takeRewrites(inside: suggestion.range, on: suggestion.side)
        guard replace(suggestion.range, in: suggestion.side, with: replacement) else {
            acceptedRewrites += earlier
            return false
        }
        let range = NSRange(location: suggestion.range.location, length: (replacement as NSString).length)
        recordRewrite(side: suggestion.side, range: range, original: suggestion.original, rewrite: replacement,
                      label: suggestion.label, suggestion: saved, earlier: earlier)
        linkAcceptedRewrite(side: suggestion.side, range: range, counterpart: counterpart)
        return true
    }

    func rejectSuggestion(_ id: UUID) {
        removeSuggestions { $0.id == id }
    }

    /// Accepts every ready suggestion in one edit per side (one undo step).
    func acceptAllSuggestions() {
        for side in [Side.left, .right] {
            let ready = suggestions.filter { s in
                guard s.side == side, s.isAcceptable else { return false }
                let ns = text(for: side) as NSString
                return NSMaxRange(s.range) <= ns.length && ns.substring(with: s.range) == s.original
            }.sorted { $0.range.location > $1.range.location }
            guard !ready.isEmpty else { continue }
            var applied: [AISuggestion] = []
            var previousStart = Int.max
            for s in ready where NSMaxRange(s.range) <= previousStart {
                applied.append(s)
                previousStart = s.range.location
            }
            let counterparts = applied.map { RewriteSession.counterpart(side: side, range: $0.range, in: self) }
            let saved = applied.map(Self.suggestionState)
            let earlier = applied.map { takeRewrites(inside: $0.range, on: side) }
            let ids = Set(ready.map(\.id))
            removeSuggestions { ids.contains($0.id) }
            var updated = text(for: side) as NSString
            for s in applied {
                updated = updated.replacingCharacters(in: s.range, with: s.fittedReplacement) as NSString
            }
            setText(updated as String, for: side)
            // Each passage moves by what the ones before it (later in `applied`) changed.
            for (i, s) in applied.enumerated() {
                let before = applied[(i + 1)...].reduce(0) { $0 + ($1.fittedReplacement as NSString).length - $1.range.length }
                let range = NSRange(location: s.range.location + before, length: (s.fittedReplacement as NSString).length)
                let carried = earlier[i].map { r -> AcceptedRewrite in
                    var r = r
                    r.range.location += before
                    return r
                }
                recordRewrite(side: side, range: range, original: s.original, rewrite: s.fittedReplacement, label: s.label,
                              suggestion: saved[i], earlier: carried)
                linkAcceptedRewrite(side: side, range: range, counterpart: counterparts[i])
            }
        }
    }

    func rejectAllSuggestions() {
        removeSuggestions { _ in true }
    }

    private func removeSuggestions(where shouldRemove: (AISuggestion) -> Bool) {
        let gone = suggestions.filter(shouldRemove)
        guard !gone.isEmpty else { return }
        for suggestion in gone { suggestion.cancelAll() }
        suggestions.removeAll(where: shouldRemove)
        if let presented = presentedSuggestion, gone.contains(where: { $0.id == presented.id }) { presentedSuggestion = nil }
        if let compared = comparedSuggestion, gone.contains(where: { $0 === compared }) { comparedSuggestion = nil }
    }

    /// Opens the next suggestion's card (after the one showing), switching to
    /// the editors if needed.
    func presentNextSuggestion() {
        guard !suggestions.isEmpty else { return }
        let ordered = suggestions.sorted { ($0.side == .left ? 0 : 1, $0.range.location) < ($1.side == .left ? 0 : 1, $1.range.location) }
        let index = presentedSuggestion.flatMap { p in ordered.firstIndex { $0.id == p.id } }.map { ($0 + 1) % ordered.count } ?? 0
        if mode != .edit { mode = .edit }
        presentedSuggestion = SuggestionPresentation(id: ordered[index].id, pinned: true)
    }

    /// Asks the window to suggest a rewrite for the current selection;
    /// `withOptions` opens the card on its settings before anything is sent.
    func suggestRewriteForSelection(withOptions: Bool = false) {
        guard let selection, !selection.text.isEmpty else { return }
        let range = SelectionRewrite.locate(selection.text, in: text(for: selection.side), near: selection.range) ?? selection.range
        if let suggestionHandler { suggestionHandler(selection.side, range, selection.text, withOptions) } else { showAI(.rewrite, selection: true) }
    }

    /// The side's text with the suggestion applied, for the side-by-side preview.
    func text(applying suggestion: AISuggestion) -> String? {
        SelectionRewrite.replacing(suggestion.range, in: text(for: suggestion.side), with: suggestion.fittedReplacement)
    }

    /// The comparison for the current texts, recomputed if the one on hand is
    /// still being worked out after an edit.
    func currentResult() -> DiffResult {
        if leftHighlights.text == leftText, rightHighlights.text == rightText { return result }
        return DiffEngine.compare(leftText, rightText, options: options)
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
        // A saved session chosen in an open panel or dropped on an editor opens
        // as a session (into this window while it's still empty).
        if SessionController.isSession(url) {
            SessionController.shared.open(url, preferring: DocumentRouter.shared.window(for: self))
            return
        }
        do {
            let text = try Self.readText(url)
            // Suggestions belong to the text being replaced.
            removeSuggestions { $0.side == side }
            releaseComments(on: side)
            if side == .left {
                leftText = text; leftName = url.lastPathComponent; leftURL = url
            } else {
                rightText = text; rightName = url.lastPathComponent; rightURL = url
            }
            restoreComments(for: url, on: side)
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
    func updateSelection(side: Side, selectedText: String, range: NSRange = NSRange(location: NSNotFound, length: 0)) {
        if selectedText.isEmpty {
            if selection?.side == side { selection = nil }
        } else {
            let next = SelectionCounts(side: side, counts: TextCounts(selectedText), text: selectedText, range: range)
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
        panel.message = "Choose the \(label.lowercased()) file, or a saved Diffactly session"
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
