import Foundation

/// Entry point of the diff engine.
///
/// Pipeline:
/// 1. **Line alignment** — lines are compared by a normalised key (indentation
///    never blocks alignment; ignore options fold case, quotes, dashes,
///    whitespace and custom strings). Small inputs use a weighted alignment that
///    favours long, contiguous, meaningful matches; large inputs use Myers.
/// 2. **Line pairing** — inside each change region, removed and added lines are
///    paired by similarity (non-crossing, maximum total similarity) so edited
///    lines appear as one *modified* row instead of a delete + insert.
/// 3. **Inline diff** — each modified pair is diffed at the requested level.
/// 4. **Move detection** — removed blocks that reappear elsewhere are linked.
public enum DiffEngine {
    public static func compare(_ left: String, _ right: String, options: DiffOptions = DiffOptions()) -> DiffResult {
        var builder = Builder(left: left, right: right, options: options)
        return builder.run()
    }

    public struct InlineChange: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case equal, removed, added }
        public var kind: Kind
        public var text: String
    }

    /// The edits inside one pair of lines in reading order (equal, removed and
    /// added runs interleaved), e.g. for `[-old-]{+new+}` style output.
    public static func inlineChanges(_ left: String, _ right: String, options: DiffOptions = DiffOptions()) -> [InlineChange] {
        let differ = InlineDiffer(normalizer: Normalizer(options: options), level: options.level)
        var pieces: [Piece]
        if left == right {
            pieces = [.equal(left, right)]
        } else if left.isEmpty || right.isEmpty {
            pieces = [.delete(left), .insert(right)]
        } else {
            switch options.level {
            case .character: pieces = differ.characterPieces(left, right)
            case .word: pieces = differ.wordPieces(left, right)
            case .smart: pieces = differ.smartPieces(left, right)
            }
        }
        return differ.applyIgnoreRules(InlineDiffer.normalize(pieces)).compactMap { p in
            switch p.op {
            case .equal: return p.right.isEmpty ? nil : InlineChange(kind: .equal, text: p.right)
            case .delete: return InlineChange(kind: .removed, text: p.left)
            case .insert: return InlineChange(kind: .added, text: p.right)
            }
        }
    }
}

private struct Builder {
    let options: DiffOptions
    let normalizer: Normalizer
    let leftSide: SideText
    let rightSide: SideText
    let deadline = Date().addingTimeInterval(4)

    var leftKeys: [String] = []
    var rightKeys: [String] = []
    var rows: [DiffRow] = []

    init(left: String, right: String, options: DiffOptions) {
        self.options = options
        self.normalizer = Normalizer(options: options)
        self.leftSide = SideText(left)
        self.rightSide = SideText(right)
    }

    mutating func run() -> DiffResult {
        leftKeys = leftSide.lines.map(normalizer.lineKey)
        rightKeys = rightSide.lines.map(normalizer.lineKey)

        // A missing newline at the end of one file is a real (if invisible)
        // change; make the final lines unequal so it surfaces.
        let newlineDiffers = leftSide.hasTrailingNewline != rightSide.hasTrailingNewline
            && !leftSide.lines.isEmpty && !rightSide.lines.isEmpty
        if newlineDiffers {
            if !leftSide.hasTrailingNewline { leftKeys[leftKeys.count - 1] += "\u{0}<no newline>" }
            if !rightSide.hasTrailingNewline { rightKeys[rightKeys.count - 1] += "\u{0}<no newline>" }
        }

        var interner = Interner()
        let a = leftKeys.map { interner.key($0) }
        let b = rightKeys.map { interner.key($0) }

        let leftLines = leftSide.lines, rightLines = rightSide.lines
        let lk = leftKeys
        var differ = SequenceDiffer()
        differ.deadline = deadline
        differ.runBonus = 0.5
        differ.weight = { i, j in
            let key = lk[i]
            let exact = leftLines[i] == rightLines[j]
            if key.isEmpty { return exact ? 0.1 : 0.099 }
            // Exact matches beat re-indented ones; longer content beats filler.
            return exact ? 1 + log(1 + Double(key.count)) : 1 - 1 / (2 + Double(key.count))
        }
        let runs = differ.diff(a, b)

        let inline = InlineDiffer(normalizer: normalizer, level: options.level, deadline: deadline)
        var k = 0
        while k < runs.count {
            let run = runs[k]
            switch run.op {
            case .equal:
                for (i, j) in zip(run.a, run.b) { appendPair(i, j, keysEqual: true, inline) }
                k += 1
            case .delete:
                if k + 1 < runs.count, runs[k + 1].op == .insert {
                    appendChangeRegion(run.a, runs[k + 1].b, inline)
                    k += 2
                } else {
                    for i in run.a { appendRemoved(i) }
                    k += 1
                }
            case .insert:
                for j in run.b { appendAdded(j) }
                k += 1
            }
        }

        let moves = options.detectMoves ? MoveDetector.detect(rows: &rows, leftKeys: leftKeys, rightKeys: rightKeys, inline: inline) : []
        let hunks = Self.hunks(rows)
        var stats = Self.stats(rows: rows, left: leftSide, right: rightSide)
        stats.trailingNewlineDiffers = leftSide.hasTrailingNewline != rightSide.hasTrailingNewline
        stats.lineEndingsDiffer = leftSide.usesCRLF != rightSide.usesCRLF && !leftSide.lines.isEmpty && !rightSide.lines.isEmpty

        return DiffResult(
            rows: rows, hunks: hunks, moves: moves, stats: stats, options: options,
            leftHasTrailingNewline: leftSide.hasTrailingNewline,
            rightHasTrailingNewline: rightSide.hasTrailingNewline
        )
    }

    // MARK: Rows

    private mutating func appendPair(_ i: Int, _ j: Int, keysEqual: Bool, _ inline: InlineDiffer) {
        let l = leftSide.lines[i], r = rightSide.lines[j]
        let out = inline.diff(l, r)
        let changed = out.hasVisibleChange || leftKeys[i] != rightKeys[j]
        let kind: RowKind = changed ? .modified : .unchanged
        rows.append(DiffRow(
            id: rows.count, kind: kind,
            left: DiffLine(number: i + 1, text: l, segments: out.left),
            right: DiffLine(number: j + 1, text: r, segments: out.right),
            moveID: nil,
            hasIgnoredDifferences: out.hasIgnoredDifferences || (!changed && l != r)
        ))
    }

    private mutating func appendRemoved(_ i: Int) {
        let l = leftSide.lines[i]
        rows.append(DiffRow(id: rows.count, kind: .removed,
                            left: DiffLine(number: i + 1, text: l, segments: [DiffSegment(l, changed: true)]),
                            right: nil, moveID: nil, hasIgnoredDifferences: false))
    }

    private mutating func appendAdded(_ j: Int) {
        let r = rightSide.lines[j]
        rows.append(DiffRow(id: rows.count, kind: .added, left: nil,
                            right: DiffLine(number: j + 1, text: r, segments: [DiffSegment(r, changed: true)]),
                            moveID: nil, hasIgnoredDifferences: false))
    }

    private mutating func appendChangeRegion(_ removed: Range<Int>, _ added: Range<Int>, _ inline: InlineDiffer) {
        let pairs = LinePairing.pair(
            removed.map { leftKeys[$0] },
            added.map { rightKeys[$0] }
        )
        var i = removed.lowerBound, j = added.lowerBound
        for (pi, pj) in pairs {
            let li = removed.lowerBound + pi, rj = added.lowerBound + pj
            while i < li { appendRemoved(i); i += 1 }
            while j < rj { appendAdded(j); j += 1 }
            appendPair(li, rj, keysEqual: false, inline)
            i = li + 1; j = rj + 1
        }
        while i < removed.upperBound { appendRemoved(i); i += 1 }
        while j < added.upperBound { appendAdded(j); j += 1 }
    }

    // MARK: Summaries

    static func hunks(_ rows: [DiffRow]) -> [DiffHunk] {
        var hunks: [DiffHunk] = []
        var i = 0
        while i < rows.count {
            guard rows[i].isChange else { i += 1; continue }
            let start = i
            var leftLo = Int.max, leftHi = Int.min, rightLo = Int.max, rightHi = Int.min
            while i < rows.count, rows[i].isChange {
                if let l = rows[i].left { leftLo = min(leftLo, l.number); leftHi = max(leftHi, l.number) }
                if let r = rows[i].right { rightLo = min(rightLo, r.number); rightHi = max(rightHi, r.number) }
                i += 1
            }
            hunks.append(DiffHunk(
                id: hunks.count, rowRange: start..<i,
                leftLines: leftLo <= leftHi ? leftLo...leftHi : nil,
                rightLines: rightLo <= rightHi ? rightLo...rightHi : nil
            ))
        }
        return hunks
    }

    static func stats(rows: [DiffRow], left: SideText, right: SideText) -> DiffStats {
        var s = DiffStats()
        s.leftLineCount = left.lines.count
        s.rightLineCount = right.lines.count
        var shared = 0
        for row in rows {
            switch row.kind {
            case .unchanged:
                s.unchangedLines += 1
                shared += row.left?.text.count ?? 0
            case .modified:
                s.modifiedLines += 1
                for seg in row.left?.segments ?? [] {
                    if seg.isChanged { count(seg.text, words: &s.removedWords, chars: &s.removedCharacters) } else { shared += seg.text.count }
                }
                for seg in row.right?.segments ?? [] where seg.isChanged {
                    count(seg.text, words: &s.addedWords, chars: &s.addedCharacters)
                }
            case .removed:
                if row.moveID != nil {
                    s.movedLines += 1
                    // Moved text is preserved content; edited moves only share their unchanged parts.
                    shared += (row.left?.segments ?? []).filter { !$0.isChanged }.reduce(0) { $0 + $1.text.count }
                } else {
                    s.removedLines += 1
                    count(row.left?.text ?? "", words: &s.removedWords, chars: &s.removedCharacters)
                }
            case .added:
                if row.moveID == nil {
                    s.addedLines += 1
                    count(row.right?.text ?? "", words: &s.addedWords, chars: &s.addedCharacters)
                }
            }
        }
        let total = left.characterCount + right.characterCount
        s.similarity = total == 0 ? (rows.contains(where: \.isChange) ? 0 : 1) : min(1, 2 * Double(shared) / Double(total))
        if rows.contains(where: \.isChange), s.similarity == 1 { s.similarity = 0.9999 }
        return s
    }

    private static func count(_ text: String, words: inout Int, chars: inout Int) {
        words += Tokenizer.wordCount(text)
        chars += text.reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) }
    }
}

/// Pairs removed lines with added lines inside one change region.
enum LinePairing {
    /// Minimum similarity for two lines to be shown as one modified line.
    static let threshold = 0.4
    /// Above this many candidate pairs, fall back to positional pairing.
    static let fullSearchLimit = 40_000

    /// Returns non-crossing `(removedIndex, addedIndex)` pairs in order.
    static func pair(_ removed: [String], _ added: [String]) -> [(Int, Int)] {
        let n = removed.count, m = added.count
        guard n > 0, m > 0 else { return [] }
        let rp = removed.map(BigramProfile.init)
        let ap = added.map(BigramProfile.init)

        if n * m > fullSearchLimit {
            return (0..<min(n, m)).compactMap { i in
                rp[i].similarity(to: ap[i]) >= threshold ? (i, i) : nil
            }
        }
        if n == 1 && m == 1 {
            // A one-for-one replacement is always shown as a modification.
            return [(0, 0)]
        }

        // Max-weight non-crossing matching (weighted LCS over similarities).
        let cols = m + 1
        var score = [Double](repeating: 0, count: (n + 1) * cols)
        var choice = [UInt8](repeating: 0, count: (n + 1) * cols) // 0 pair, 1 skip removed, 2 skip added
        for i in 1...n {
            for j in 1...m {
                var best = score[(i - 1) * cols + j]
                var c: UInt8 = 1
                let left = score[i * cols + j - 1]
                if left > best { best = left; c = 2 }
                let sim = rp[i - 1].similarity(to: ap[j - 1])
                if sim >= threshold {
                    // Prefer pairs that keep their relative position.
                    let candidate = score[(i - 1) * cols + j - 1] + sim - 0.001 * Double(abs((i - 1) - (j - 1)))
                    if candidate > best { best = candidate; c = 0 }
                }
                score[i * cols + j] = best
                choice[i * cols + j] = c
            }
        }
        var pairs: [(Int, Int)] = []
        var i = n, j = m
        while i > 0 && j > 0 {
            switch choice[i * cols + j] {
            case 0: pairs.append((i - 1, j - 1)); i -= 1; j -= 1
            case 1: i -= 1
            default: j -= 1
            }
        }
        return pairs.reversed()
    }
}
