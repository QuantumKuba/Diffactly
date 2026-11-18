import Foundation
import DiffactlyCore

/// A passage in the left text paired with the one in the right text that
/// says the same thing, for when the comparison can't line them up on its
/// own (a rewrite changed most of the words, say). Links are made by hand,
/// or when an AI rewrite is accepted (paired with what the passage matched
/// before its words changed). They follow their text through edits, take the
/// place of the automatic match for rewrites, and show as ribbons in Split.
struct PassageLink: Identifiable, Equatable {
    let id: UUID
    var left: NSRange
    var leftText: String
    var right: NSRange
    var rightText: String
    /// Made when an AI rewrite was accepted, rather than by the user.
    var isAutomatic: Bool

    init(id: UUID = UUID(), left: NSRange, leftText: String, right: NSRange, rightText: String, isAutomatic: Bool = false) {
        self.id = id
        self.left = left
        self.leftText = leftText
        self.right = right
        self.rightText = rightText
        self.isAutomatic = isAutomatic
    }

    func range(on side: DiffDocument.Side) -> NSRange { side == .left ? left : right }
    func text(on side: DiffDocument.Side) -> String { side == .left ? leftText : rightText }

    mutating func set(_ range: NSRange, text: String, on side: DiffDocument.Side) {
        if side == .left { left = range; leftText = text } else { right = range; rightText = text }
    }
}

/// The first half of a link being made: text picked on one side, waiting
/// for the matching text on the other.
struct PendingLinkEnd: Equatable {
    var side: DiffDocument.Side
    var range: NSRange
    var text: String
}

/// How a link is painted in one editor.
struct LinkMark: Equatable {
    var id: UUID
    var range: NSRange
    /// Its other end is under the pointer (or it's the half being linked).
    var isHighlighted: Bool
    var isPending = false
}

/// Edits the editor's context menu asks for.
enum LinkAction {
    /// Picks the selection as one end of a link, or finishes one.
    case linkSelection(NSRange)
    case reveal(UUID)
    case remove(UUID)
    case cancelPending
}

extension DiffDocument {

    /// Links `left` and `right`. A link already joining text that overlaps
    /// both is replaced. nil when either range is blank or out of bounds.
    @discardableResult
    func link(left: NSRange, right: NSRange, automatic: Bool = false) -> PassageLink? {
        let l = leftText as NSString, r = rightText as NSString
        guard left.length > 0, right.length > 0, NSMaxRange(left) <= l.length, NSMaxRange(right) <= r.length else { return nil }
        let leftText = l.substring(with: left), rightText = r.substring(with: right)
        guard !leftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !rightText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        links.removeAll { NSIntersectionRange($0.left, left).length > 0 && NSIntersectionRange($0.right, right).length > 0 }
        let link = PassageLink(left: left, leftText: leftText, right: right, rightText: rightText, isAutomatic: automatic)
        links.append(link)
        return link
    }

    /// ⌥⌘L: the first press picks the selection as one end; the second, with
    /// text selected on the other side, links the two. Picking again on the
    /// same side moves the first end.
    func linkSelection() {
        guard let selection, !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let range = SelectionRewrite.locate(selection.text, in: text(for: selection.side), near: selection.range) ?? selection.range
        linkRange(range, on: selection.side)
    }

    func linkRange(_ range: NSRange, on side: Side) {
        let ns = text(for: side) as NSString
        guard range.length > 0, NSMaxRange(range) <= ns.length else { return }
        if let anchor = pendingLink, anchor.side != side, isCurrent(anchor) {
            let made = side == .right ? link(left: anchor.range, right: range) : link(left: range, right: anchor.range)
            pendingLink = nil
            if let made { hoveredLinkID = made.id }
        } else {
            pendingLink = PendingLinkEnd(side: side, range: range, text: ns.substring(with: range))
        }
    }

    func cancelPendingLink() { pendingLink = nil }

    func removeLink(_ id: UUID) {
        links.removeAll { $0.id == id }
        if hoveredLinkID == id { hoveredLinkID = nil }
    }

    func removeAllLinks() {
        links = []
        hoveredLinkID = nil
    }

    func handle(_ action: LinkAction, on side: Side) {
        switch action {
        case .linkSelection(let range): linkRange(range, on: side)
        case .reveal(let id): revealLinkedText(id, from: side)
        case .remove(let id): removeLink(id)
        case .cancelPending: cancelPendingLink()
        }
    }

    /// Selects and scrolls to the other end of a link.
    func revealLinkedText(_ id: UUID, from side: Side) {
        guard let link = links.first(where: { $0.id == id }) else { return }
        let other = side.other
        if mode != .edit { mode = .edit }
        hoveredLinkID = id
        selectionRequest = SelectionRequest(side: other, range: link.range(on: other))
        updateSelection(side: other, selectedText: link.text(on: other), range: link.range(on: other))
    }

    /// The links touching `index` on `side`, smallest first.
    func links(at index: Int, on side: Side) -> [PassageLink] {
        links.filter { NSLocationInRange(index, $0.range(on: side)) }.sorted { $0.range(on: side).length < $1.range(on: side).length }
    }

    func linkMarks(for side: Side) -> [LinkMark] {
        var marks = links.map { LinkMark(id: $0.id, range: $0.range(on: side), isHighlighted: $0.id == hoveredLinkID) }
        if let anchor = pendingLink, anchor.side == side {
            marks.append(LinkMark(id: UUID(), range: anchor.range, isHighlighted: true, isPending: true))
        }
        return marks
    }

    /// The other side's text linked to a passage on `side`, as a counterpart
    /// (nil when no link touches it). Several links are joined in reading order.
    func linkedCounterpart(forPassageOn side: Side, range: NSRange, passage: String) -> PassageMatch.Match? {
        let other = side.other
        let touching = links.filter { NSIntersectionRange($0.range(on: side), range).length > 0 }
        guard !touching.isEmpty else { return nil }
        return PassageMatch.marked(touching.map { $0.range(on: other) }, in: text(for: other), passage: passage)
    }

    /// After a rewrite was accepted into `range` on `side`: links it to what
    /// the passage matched on the other side before (`counterpart`), unless a
    /// link already covers it.
    func linkAcceptedRewrite(side: Side, range: NSRange, counterpart: PassageMatch.Match?) {
        guard let counterpart, !links.contains(where: { NSIntersectionRange($0.range(on: side), range).length > 0 }) else { return }
        let otherText = text(for: side.other) as NSString
        guard let other = Self.range(ofLines: counterpart.lines, in: otherText) else { return }
        if side == .right { link(left: other, right: range, automatic: true) } else { link(left: range, right: other, automatic: true) }
    }

    /// The text from the start of the first of `lines` (1-based) to the end
    /// of the last, without the final line break.
    static func range(ofLines lines: [Int], in text: NSString) -> NSRange? {
        guard let first = lines.min(), let last = lines.max(), first >= 1 else { return nil }
        var starts = [0]
        var search = NSRange(location: 0, length: text.length)
        while starts.count <= last {
            let found = text.range(of: "\n", options: .literal, range: search)
            guard found.location != NSNotFound else { break }
            starts.append(NSMaxRange(found))
            search = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
        }
        guard first <= starts.count else { return nil }
        let start = starts[first - 1]
        var end = last < starts.count ? starts[last] : text.length
        while end > start, let scalar = Unicode.Scalar(text.character(at: end - 1)), CharacterSet.newlines.contains(scalar) { end -= 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    /// The 1-based lines `range` spans in `side`'s text.
    func lines(of range: NSRange, on side: Side) -> ClosedRange<Int> {
        let ns = text(for: side) as NSString
        func line(at index: Int) -> Int {
            var line = 1, i = 0
            let end = min(index, ns.length)
            while i < end {
                if ns.character(at: i) == 0x0A { line += 1 }
                i += 1
            }
            return line
        }
        let first = line(at: range.location)
        let last = line(at: max(range.location, NSMaxRange(range) - 1))
        return first...max(first, last)
    }

    private func isCurrent(_ anchor: PendingLinkEnd) -> Bool {
        let ns = text(for: anchor.side) as NSString
        return NSMaxRange(anchor.range) <= ns.length && ns.substring(with: anchor.range) == anchor.text
    }

    /// Moves each link's end on `side` with its text. A link whose text is
    /// gone on either side is dropped.
    func trackLinks(on side: Side, from old: String) {
        if let anchor = pendingLink, anchor.side == side {
            let new = text(for: side)
            switch TrackedRange.follow(anchor.range, passage: anchor.text, old: old, new: new) {
            case .intact(let range), .edited(let range):
                pendingLink = range.length > 0 ? PendingLinkEnd(side: side, range: range, text: (new as NSString).substring(with: range)) : nil
            case .removed:
                pendingLink = nil
            }
        }
        guard !links.isEmpty else { return }
        let new = text(for: side)
        let ns = new as NSString
        let change = TrackedRange.changedRanges(old: old, new: new)
        var updated: [PassageLink] = []
        for var link in links {
            let outcome = new.isEmpty ? .removed : TrackedRange.follow(link.range(on: side), passage: link.text(on: side), change: change, new: new)
            switch outcome {
            case .intact(let range), .edited(let range):
                guard range.length > 0, NSMaxRange(range) <= ns.length else { continue }
                link.set(range, text: ns.substring(with: range), on: side)
                updated.append(link)
            case .removed:
                continue
            }
        }
        if updated != links { links = updated }
    }
}
