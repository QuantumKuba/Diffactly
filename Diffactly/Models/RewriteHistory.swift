import Foundation
import DiffactlyCore

/// A passage an AI rewrite was accepted into. It keeps what the passage said
/// before, each rewrite accepted on top of it, and the versions the last one
/// was picked from, so the text can be compared with any of them, put back,
/// or reopened as a suggestion. Nothing about it changes the text by itself.
struct AcceptedRewrite: Identifiable, Equatable {
    /// One accepted rewrite: the text it replaced and what it put in.
    struct Step: Equatable {
        var original: String
        var rewrite: String
        /// What produced it, e.g. "Humanize · Moderate · gpt-5".
        var label: String
        var date: Date
        /// The suggestion it was accepted from (every version and rewritten
        /// part), to reopen it; nil for rewrites from the AI panel and for
        /// steps that no longer line up with the passage.
        var suggestion: SessionManifest.SuggestionState?
    }

    enum State: Equatable {
        /// Reads as the last rewrite accepted.
        case applied
        /// Back to the text from before any rewrite.
        case reverted
        /// Reads as another step (`index` into `texts`).
        case step(Int)
        /// Edited by hand since.
        case edited
    }

    let id: UUID
    var side: DiffDocument.Side
    /// Where the passage is now (UTF-16, kept current through edits).
    var range: NSRange
    /// The passage as it reads now.
    var text: String
    /// Oldest first; never empty.
    var steps: [Step]

    init(id: UUID = UUID(), side: DiffDocument.Side, range: NSRange, text: String, steps: [Step]) {
        self.id = id
        self.side = side
        self.range = range
        self.text = text
        self.steps = steps
    }

    /// The passage before the first rewrite.
    var original: String { steps.first?.original ?? text }
    /// The last rewrite accepted.
    var latest: String { steps.last?.rewrite ?? text }

    /// Every text the passage has had: the original, then each rewrite.
    var texts: [String] { [original] + steps.map(\.rewrite) }

    var state: State {
        if text == latest { return .applied }
        if text == original { return .reverted }
        if let i = texts.firstIndex(of: text) { return .step(i) }
        return .edited
    }

    /// The step on show in the editor, as an index into `texts`; nil when edited.
    var currentIndex: Int? { texts.lastIndex(of: text) }
}

extension DiffDocument {

    /// One side's accepted rewrites in reading order.
    func acceptedRewrites(for side: Side) -> [AcceptedRewrite] {
        acceptedRewrites.filter { $0.side == side }.sorted { $0.range.location < $1.range.location }
    }

    func acceptedRewrite(id: UUID?) -> AcceptedRewrite? {
        guard let id else { return nil }
        return acceptedRewrites.first { $0.id == id }
    }

    /// Takes the records inside `range` off the list, before the range is
    /// replaced, to carry into the record of what replaces it.
    func takeRewrites(inside range: NSRange, on side: Side) -> [AcceptedRewrite] {
        let inside = acceptedRewrites.filter {
            $0.side == side && $0.range.location >= range.location && NSMaxRange($0.range) <= NSMaxRange(range)
        }
        let ids = Set(inside.map(\.id))
        acceptedRewrites.removeAll { ids.contains($0.id) }
        return inside
    }

    /// Remembers that `range` on `side` now holds `rewrite` in place of
    /// `original`. `earlier` are the records that were inside the replaced
    /// text (from `takeRewrites`): their steps come first, so the passage's
    /// first original is never lost.
    @discardableResult
    func recordRewrite(side: Side, range: NSRange, original: String, rewrite: String, label: String,
                       suggestion: SessionManifest.SuggestionState? = nil, earlier: [AcceptedRewrite] = [],
                       date: Date = Date()) -> AcceptedRewrite? {
        guard original != rewrite else { return nil }
        let step = AcceptedRewrite.Step(original: original, rewrite: rewrite, label: label, date: date, suggestion: suggestion)
        var steps: [AcceptedRewrite.Step] = []
        let replacedLength = (original as NSString).length
        if let previous = earlier.max(by: { $0.range.length < $1.range.length }),
           previous.range.location >= range.location, NSMaxRange(previous.range) <= range.location + replacedLength {
            // Widen its steps to the whole passage that was replaced.
            let ns = original as NSString
            let prefix = ns.substring(to: previous.range.location - range.location)
            let suffix = ns.substring(from: NSMaxRange(previous.range) - range.location)
            let same = prefix.isEmpty && suffix.isEmpty
            steps = previous.steps.map { s in
                var s = s
                s.original = prefix + s.original + suffix
                s.rewrite = prefix + s.rewrite + suffix
                // Reopening a step needs the passage it was asked for exactly.
                if !same { s.suggestion = nil }
                return s
            }
        }
        let record = AcceptedRewrite(side: side, range: range, text: rewrite, steps: steps + [step])
        acceptedRewrites.append(record)
        return record
    }

    /// Puts `texts[index]` of a rewrite's history back into the passage (one
    /// undoable edit). Index 0 is the original.
    @discardableResult
    func showRewriteStep(_ index: Int, of id: UUID) -> Bool {
        guard let record = acceptedRewrite(id: id), record.texts.indices.contains(index) else { return false }
        let target = record.texts[index]
        guard target != record.text, currentText(record) else { return false }
        return replace(record.range, in: record.side, with: target)
    }

    func revertRewrite(_ id: UUID) { showRewriteStep(0, of: id) }

    /// Puts the passage back as it was before the last rewrite and opens that
    /// rewrite's suggestion again, with all its versions and rewritten parts,
    /// to pick again. The step leaves the history (accepting adds it back).
    @discardableResult
    func reopenRewrite(_ id: UUID) -> AISuggestion? {
        guard let record = acceptedRewrite(id: id), let step = record.steps.last, let saved = step.suggestion,
              record.text == step.rewrite, currentText(record) else { return nil }
        let location = record.range.location
        guard replace(record.range, in: record.side, with: step.original) else { return nil }
        let range = NSRange(location: location, length: (step.original as NSString).length)
        if let i = acceptedRewrites.firstIndex(where: { $0.id == id }) {
            if record.steps.count == 1 {
                acceptedRewrites.remove(at: i)
            } else {
                acceptedRewrites[i].steps.removeLast()
            }
        }
        var state = saved
        state.side = record.side
        state.location = range.location
        state.length = range.length
        guard let suggestion = restoredSuggestion(state) else { return nil }
        suggestion.status = .ready
        addSuggestion(suggestion)
        return suggestion
    }

    /// Stops keeping a passage's history; the text stays as it is.
    func forgetRewrite(_ id: UUID) {
        acceptedRewrites.removeAll { $0.id == id }
        if presentedSuggestion?.id == id { presentedSuggestion = nil }
    }

    func forgetAllRewrites() {
        if let id = presentedSuggestion?.id, acceptedRewrite(id: id) != nil { presentedSuggestion = nil }
        acceptedRewrites = []
    }

    /// The record still points at its text (the editor hasn't moved on).
    private func currentText(_ record: AcceptedRewrite) -> Bool {
        let ns = text(for: record.side) as NSString
        return NSMaxRange(record.range) <= ns.length && ns.substring(with: record.range) == record.text
    }

    /// Moves each record on `side` along with its passage. An edit inside it
    /// (including putting back an earlier step) leaves it covering the new
    /// text; one whose passage is gone is dropped.
    func trackAcceptedRewrites(on side: Side, from old: String) {
        guard acceptedRewrites.contains(where: { $0.side == side }) else { return }
        let new = text(for: side)
        let ns = new as NSString
        let change = TrackedRange.changedRanges(old: old, new: new)
        var updated: [AcceptedRewrite] = []
        for var record in acceptedRewrites {
            guard record.side == side else { updated.append(record); continue }
            let outcome = new.isEmpty ? .removed : TrackedRange.follow(record.range, passage: record.text, change: change, new: new)
            switch outcome {
            case .intact(let range), .edited(let range):
                guard range.length > 0, NSMaxRange(range) <= ns.length else { continue }
                record.range = range
                record.text = ns.substring(with: range)
                updated.append(record)
            case .removed:
                continue
            }
        }
        if updated != acceptedRewrites { acceptedRewrites = updated }
    }

    /// The editor marks for accepted rewrites (clicked, not hovered, to open).
    func rewriteMarks(for side: Side) -> [SuggestionMark] {
        acceptedRewrites(for: side).map {
            SuggestionMark(id: $0.id, range: $0.range, style: $0.state == .applied ? .accepted : .history)
        }
    }

    /// The side's text with the passage reading `texts[index]`, for previews.
    func text(for record: AcceptedRewrite, showing index: Int) -> String? {
        guard record.texts.indices.contains(index) else { return nil }
        return SelectionRewrite.replacing(record.range, in: text(for: record.side), with: record.texts[index])
    }
}
