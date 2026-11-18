import Foundation

/// Finds the part of the other text that lines up with a passage selected on
/// one side, using the computed comparison: paired lines, the changed block a
/// removed or added line belongs to, moves and split/merge relations.
public enum PassageMatch {

    public struct Match: Equatable, Sendable {
        /// 1-based line numbers on the other side (ascending, possibly with gaps).
        public var lines: [Int]
        /// Those lines' text. Separate runs are joined with an omission marker.
        public var text: String
        /// The other side says the same thing (no change in these lines).
        public var isIdentical: Bool
        /// The user marked this text by hand rather than it being matched
        /// from the comparison, so it's taken as the counterpart as is.
        public var isMarked: Bool

        public init(lines: [Int], text: String, isIdentical: Bool, isMarked: Bool = false) {
            self.lines = lines
            self.text = text
            self.isIdentical = isIdentical
            self.isMarked = isMarked
        }
    }

    /// Longest counterpart handed to a model; a bigger one is cut.
    public static let characterLimit = 24_000

    /// - Parameters:
    ///   - result: the comparison of `text` (on `fromLeft`'s side) with `otherText`.
    ///   - range: the passage, as a UTF-16 range in `text`.
    public static func counterpart(in result: DiffResult, fromLeft: Bool, range: NSRange, text: String, otherText: String) -> Match? {
        let ns = text as NSString
        guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= ns.length else { return nil }
        let first = lineNumber(at: range.location, in: ns)
        let last = lineNumber(at: NSMaxRange(range) - 1, in: ns)
        let selected = first...last

        func mine(_ row: DiffRow) -> DiffLine? { fromLeft ? row.left : row.right }
        func theirs(_ row: DiffRow) -> DiffLine? { fromLeft ? row.right : row.left }

        var lines = Set<Int>()
        var changed = false
        for (index, row) in result.rows.enumerated() {
            guard let line = mine(row), selected.contains(line.number) else { continue }
            if row.kind != .unchanged || row.hasIgnoredDifferences { changed = true }
            if let other = theirs(row) {
                lines.insert(other.number)
            } else if let move = result.move(id: row.moveID) {
                lines.formUnion(fromLeft ? Array(move.to) : Array(move.from))
            } else if let hunk = result.hunks.first(where: { $0.rowRange.contains(index) }),
                      let otherLines = fromLeft ? hunk.rightLines : hunk.leftLines {
                // A removed (or added) line: its counterpart is whatever the
                // other side has in the same changed block.
                lines.formUnion(Array(otherLines))
            }
        }
        for relation in result.relations where selected.contains(fromLeft ? relation.left : relation.right) {
            lines.insert(fromLeft ? relation.right : relation.left)
            changed = true
        }
        guard !lines.isEmpty else { return nil }

        let sorted = lines.sorted()
        let otherLines = otherText.components(separatedBy: "\n")
        var runs: [[String]] = []
        var previous = Int.min
        for number in sorted where number >= 1 && number <= otherLines.count {
            if number != previous + 1 { runs.append([]) }
            runs[runs.count - 1].append(otherLines[number - 1])
            previous = number
        }
        var joined = runs.map { $0.joined(separator: "\n") }.joined(separator: "\n[…]\n")
        guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if joined.count > characterLimit { joined = String(joined.prefix(characterLimit)) + "\n[… rest omitted …]" }
        return Match(lines: sorted, text: joined, isIdentical: !changed)
    }

    /// The counterpart the user marked by hand: the marked parts of the other
    /// text, in reading order, joined with an omission marker. nil when the
    /// marks hold no text.
    /// - Parameters:
    ///   - ranges: UTF-16 ranges in `otherText` (out-of-bounds ones are skipped).
    ///   - passage: the passage being rewritten; marks that say exactly the
    ///     same thing make the match identical.
    public static func marked(_ ranges: [NSRange], in otherText: String, passage: String = "") -> Match? {
        let ns = otherText as NSString
        let valid = ranges
            .filter { $0.location != NSNotFound && $0.length > 0 && NSMaxRange($0) <= ns.length }
            .sorted { $0.location < $1.location }
        let pieces = valid.map { ns.substring(with: $0) }
        guard pieces.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
        var lines = Set<Int>()
        for range in valid {
            lines.formUnion(lineNumber(at: range.location, in: ns)...lineNumber(at: NSMaxRange(range) - 1, in: ns))
        }
        var joined = pieces.joined(separator: "\n[…]\n")
        if joined.count > characterLimit { joined = String(joined.prefix(characterLimit)) + "\n[… rest omitted …]" }
        let same = !passage.isEmpty && joined.trimmingCharacters(in: .whitespacesAndNewlines) == passage.trimmingCharacters(in: .whitespacesAndNewlines)
        return Match(lines: lines.sorted(), text: joined, isIdentical: same, isMarked: true)
    }

    /// 1-based line number of the line containing UTF-16 offset `index`.
    static func lineNumber(at index: Int, in ns: NSString) -> Int {
        var line = 1
        var search = NSRange(location: 0, length: min(index, ns.length))
        while search.length > 0 {
            let found = ns.range(of: "\n", options: .literal, range: search)
            guard found.location != NSNotFound else { break }
            line += 1
            let next = NSMaxRange(found)
            search = NSRange(location: next, length: min(index, ns.length) - next)
        }
        return line
    }
}

// MARK: - Following a range through edits

/// Keeps a UTF-16 range pointing at the same text while the text around it is
/// edited, e.g. a pending AI suggestion while the user keeps typing.
public enum TrackedRange {

    /// The smallest ranges (old and new, UTF-16) that turn `old` into `new`:
    /// everything outside them is a shared prefix or suffix. Never splits a
    /// composed character such as an emoji or an accented letter.
    public static func changedRanges(old: String, new: String) -> (old: NSRange, new: NSRange) {
        let a = Array(old.utf16), b = Array(new.utf16)
        var prefix = 0
        let limit = min(a.count, b.count)
        while prefix < limit, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let oldNS = old as NSString, newNS = new as NSString
        // Back the prefix up to the start of the character it ends inside.
        for ns in [oldNS, newNS] where prefix > 0 && prefix < ns.length {
            prefix = min(prefix, ns.rangeOfComposedCharacterSequence(at: prefix).location)
        }
        // Shrink the suffix so it starts at a character boundary in both strings.
        for ns in [oldNS, newNS] where suffix > 0 {
            let boundary = ns.length - suffix
            guard boundary > prefix, boundary < ns.length else { continue }
            let r = ns.rangeOfComposedCharacterSequence(at: boundary)
            if r.location < boundary { suffix = ns.length - NSMaxRange(r) }
        }
        suffix = min(suffix, a.count - prefix, b.count - prefix)
        return (NSRange(location: prefix, length: a.count - prefix - suffix),
                NSRange(location: prefix, length: b.count - prefix - suffix))
    }

    public enum Outcome: Equatable {
        /// `passage` is still there, now at this range.
        case intact(NSRange)
        /// The edit touched the passage; the range now covers what's left of it.
        case edited(NSRange)
        /// The passage is gone (e.g. the whole text was replaced or cleared).
        case removed
    }

    /// Where `passage`, last seen at `range` in `old`, is in `new`.
    public static func follow(_ range: NSRange, passage: String, old: String, new: String) -> Outcome {
        if new.isEmpty { return .removed }
        return follow(range, passage: passage, change: changedRanges(old: old, new: new), new: new)
    }

    /// `follow` for an edit already measured with `changedRanges`, so many
    /// ranges in one text can share a single comparison.
    public static func follow(_ range: NSRange, passage: String, change: (old: NSRange, new: NSRange), new: String) -> Outcome {
        let newNS = new as NSString
        if new.isEmpty { return .removed }
        let delta = change.new.length - change.old.length
        var moved = range
        if NSMaxRange(change.old) <= range.location {
            moved.location += delta                       // edit before the passage
        } else if change.old.location >= NSMaxRange(range) {
            // edit after the passage: nothing moves
        } else {
            // The edit overlaps the passage. The prefix/suffix diff can place an
            // edit next to the passage inside it (typing the passage's first
            // letter just before it), so check whether the text survived.
            let start = min(range.location, change.new.location)
            let end = max(NSMaxRange(range) + delta, NSMaxRange(change.new))
            moved = NSRange(location: max(0, start), length: max(0, min(newNS.length, end) - max(0, start)))
            if let found = SelectionRewrite.locate(passage, in: new, near: NSRange(location: range.location, length: range.length)),
               NSIntersectionRange(found, moved).length > 0 || found.location == moved.location {
                return .intact(found)
            }
            return moved.length > 0 ? .edited(moved) : .removed
        }
        if NSMaxRange(moved) <= newNS.length, newNS.substring(with: moved) == passage { return .intact(moved) }
        if let found = SelectionRewrite.locate(passage, in: new, near: moved) { return .intact(found) }
        return .removed
    }

    /// Where a single position (e.g. where a deleted passage used to be) ends
    /// up after the edit: shifted by edits before it, pulled to the start of
    /// an edit that covers it.
    public static func shift(_ location: Int, change: (old: NSRange, new: NSRange)) -> Int {
        if NSMaxRange(change.old) <= location { return location + change.new.length - change.old.length }
        if change.old.location < location { return change.new.location }
        return location
    }
}
