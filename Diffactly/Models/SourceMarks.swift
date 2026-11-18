import Foundation
import DiffactlyCore

/// A stretch of text the user highlighted in one editor so passage rewrites
/// know exactly what to draw on. Marks on the other side replace the
/// automatically matched counterpart; marks elsewhere on the passage's own
/// side are sent as extra excerpts.
struct SourceMark: Identifiable, Equatable {
    let id: UUID
    var side: DiffDocument.Side
    /// Where the text is now (UTF-16, kept current through edits).
    var range: NSRange
    /// The marked text, as it reads now.
    var text: String

    init(id: UUID = UUID(), side: DiffDocument.Side, range: NSRange, text: String) {
        self.id = id
        self.side = side
        self.range = range
        self.text = text
    }
}

/// Edits the editor's context menu asks for.
enum SourceMarkAction {
    case add(NSRange)
    /// Removes the mark covering this UTF-16 offset.
    case remove(at: Int)
    case clearSide
    case clearAll
}

extension DiffDocument {

    /// One side's marks in reading order.
    func sourceMarks(for side: Side) -> [SourceMark] {
        sourceMarks.filter { $0.side == side }.sorted { $0.range.location < $1.range.location }
    }

    /// Marks a range. Overlapping or touching marks on the same side merge
    /// into one, so marking a bit more of a paragraph just grows its mark.
    func markSource(_ range: NSRange, on side: Side) {
        let ns = text(for: side) as NSString
        guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= ns.length,
              !ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var merged = range
        let touching = sourceMarks.filter {
            $0.side == side && NSMaxRange($0.range) >= merged.location && $0.range.location <= NSMaxRange(merged)
        }
        for mark in touching { merged = NSUnionRange(merged, mark.range) }
        let ids = Set(touching.map(\.id))
        sourceMarks.removeAll { ids.contains($0.id) }
        sourceMarks.append(SourceMark(side: side, range: merged, text: ns.substring(with: merged)))
    }

    /// Removes the mark covering `index` (or ending right at it).
    func removeSourceMark(at index: Int, on side: Side) {
        guard let mark = sourceMark(at: index, on: side) else { return }
        sourceMarks.removeAll { $0.id == mark.id }
    }

    func removeSourceMark(_ id: UUID) {
        sourceMarks.removeAll { $0.id == id }
    }

    func sourceMark(at index: Int, on side: Side) -> SourceMark? {
        sourceMarks.first { $0.side == side && (NSLocationInRange(index, $0.range) || NSMaxRange($0.range) == index) }
    }

    /// Selects and scrolls to the mark after the current selection (wrapping).
    func revealNextSourceMark() {
        let ordered = sourceMarks(for: .left) + sourceMarks(for: .right)
        guard !ordered.isEmpty else { return }
        let current = selection.flatMap { s in ordered.firstIndex { $0.side == s.side && $0.range == s.range } }
        let mark = ordered[current.map { ($0 + 1) % ordered.count } ?? 0]
        if mode != .edit { mode = .edit }
        selectionRequest = SelectionRequest(side: mark.side, range: mark.range)
        updateSelection(side: mark.side, selectedText: mark.text, range: mark.range)
    }

    /// Clears one side's marks, or both sides' (nil).
    func clearSourceMarks(on side: Side? = nil) {
        sourceMarks.removeAll { side == nil || $0.side == side }
    }

    func handle(_ action: SourceMarkAction, on side: Side) {
        switch action {
        case .add(let range): markSource(range, on: side)
        case .remove(let index): removeSourceMark(at: index, on: side)
        case .clearSide: clearSourceMarks(on: side)
        case .clearAll: clearSourceMarks()
        }
    }

    /// Menu command: marks the selection, or unmarks it when it's already
    /// inside a mark.
    func toggleSourceMarkForSelection() {
        guard let selection, !selection.text.isEmpty else { return }
        let range = SelectionRewrite.locate(selection.text, in: text(for: selection.side), near: selection.range) ?? selection.range
        if let mark = sourceMarks.first(where: { $0.side == selection.side && NSIntersectionRange($0.range, range) == range }) {
            removeSourceMark(mark.id)
        } else {
            markSource(range, on: selection.side)
        }
    }

    /// Whether the selection is already covered by a mark (for menu titles).
    var selectionIsSourceMarked: Bool {
        guard let selection, !selection.text.isEmpty else { return false }
        return sourceMarks.contains { $0.side == selection.side && NSIntersectionRange($0.range, selection.range) == selection.range }
    }

    /// Moves each mark on `side` along with its text. A mark whose text was
    /// edited keeps covering what's left of it; one whose text is gone is dropped.
    func trackSourceMarks(on side: Side, from old: String) {
        guard sourceMarks.contains(where: { $0.side == side }) else { return }
        let new = text(for: side)
        let ns = new as NSString
        var updated: [SourceMark] = []
        for var mark in sourceMarks {
            guard mark.side == side else { updated.append(mark); continue }
            switch TrackedRange.follow(mark.range, passage: mark.text, old: old, new: new) {
            case .intact(let range), .edited(let range):
                guard range.length > 0, NSMaxRange(range) <= ns.length else { continue }
                mark.range = range
                mark.text = ns.substring(with: range)
                if !mark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { updated.append(mark) }
            case .removed:
                continue
            }
        }
        if updated != sourceMarks { sourceMarks = updated }
    }

    /// The other side's text the user marked for a passage on `side`, as a
    /// counterpart (nil when nothing is marked there).
    func markedCounterpart(forPassageOn side: Side, passage: String) -> PassageMatch.Match? {
        let marks = sourceMarks(for: side.other)
        guard !marks.isEmpty else { return nil }
        return PassageMatch.marked(marks.map(\.range), in: text(for: side.other), passage: passage)
    }

    /// Marks on the passage's own side outside the passage, as excerpts.
    func markedExcerpts(on side: Side, excluding range: NSRange) -> [String] {
        sourceMarks(for: side)
            .filter { NSIntersectionRange($0.range, range).length == 0 }
            .map(\.text)
    }
}
