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
    var prose = ProseIndex(left: [], right: [])

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

        prose = ProseIndex(left: leftKeys, right: rightKeys)
        let inline = InlineDiffer(normalizer: normalizer, level: options.level, deadline: deadline)
        for region in regions(runs) {
            switch region {
            case .equal(let a, let b):
                for (i, j) in zip(a, b) { appendPair(i, j, keysEqual: true, inline) }
            case .change(let a, let b):
                if a.isEmpty { for j in b { appendAdded(j) } }
                else if b.isEmpty { for i in a { appendRemoved(i) } }
                else { appendChangeRegion(a, b, inline) }
            }
        }

        let moves = options.detectMoves ? MoveDetector.detect(rows: &rows, leftKeys: leftKeys, rightKeys: rightKeys, inline: inline, prose: prose) : []
        let relations = options.detectMoves ? MoveDetector.relations(rows: rows, prose: prose) : []
        let hunks = Self.hunks(rows)
        var stats = Self.stats(rows: rows, left: leftSide, right: rightSide)
        stats.trailingNewlineDiffers = leftSide.hasTrailingNewline != rightSide.hasTrailingNewline
        stats.lineEndingsDiffer = leftSide.usesCRLF != rightSide.usesCRLF && !leftSide.lines.isEmpty && !rightSide.lines.isEmpty

        return DiffResult(
            rows: rows, hunks: hunks, moves: moves, relations: relations, stats: stats, options: options,
            leftHasTrailingNewline: leftSide.hasTrailingNewline,
            rightHasTrailingNewline: rightSide.hasTrailingNewline
        )
    }

    // MARK: Regions

    enum Region {
        case equal(Range<Int>, Range<Int>)
        case change(Range<Int>, Range<Int>)
    }

    /// Groups the alignment into equal runs and change regions. Two change
    /// regions separated only by blank lines are merged when they hold prose:
    /// paragraphs are separated by blank lines, which the aligner happily
    /// matches one paragraph out of step — cutting a rewritten section into
    /// 1×1 regions that would each force-pair unrelated paragraphs.
    private func regions(_ runs: [EditRun]) -> [Region] {
        var out: [Region] = []
        var k = 0
        while k < runs.count {
            let run = runs[k]
            switch run.op {
            case .equal:
                out.append(.equal(run.a, run.b)); k += 1
            case .delete:
                if k + 1 < runs.count, runs[k + 1].op == .insert {
                    out.append(.change(run.a, runs[k + 1].b)); k += 2
                } else {
                    out.append(.change(run.a, run.b.lowerBound..<run.b.lowerBound)); k += 1
                }
            case .insert:
                out.append(.change(run.a.lowerBound..<run.a.lowerBound, run.b)); k += 1
            }
        }
        var merged: [Region] = []
        for region in out {
            if case .change(let a2, let b2) = region,
               merged.count >= 2,
               case .equal(let ea, _) = merged[merged.count - 1],
               case .change(let a1, let b1) = merged[merged.count - 2],
               ea.count <= 2, ea.allSatisfy({ leftKeys[$0].isEmpty }) {
                let a = a1.lowerBound..<a2.upperBound, b = b1.lowerBound..<b2.upperBound
                if a.contains(where: { prose.isProse(.left, $0) }) && b.contains(where: { prose.isProse(.right, $0) }) {
                    merged.removeLast(2)
                    merged.append(.change(a, b))
                    continue
                }
            }
            merged.append(region)
        }
        return merged
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
        let prose = prose
        let pairs = LinePairing.pair(
            removed.map { leftKeys[$0] },
            added.map { rightKeys[$0] },
            prose: { prose.similarity(left: removed.lowerBound + $0, right: added.lowerBound + $1) }
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
    ///
    /// `prose` gives a content-word similarity for two lines that are both prose
    /// paragraphs (nil otherwise); it replaces the character measure for them,
    /// which rates any two paragraphs on the same topic as alike.
    static func pair(_ removed: [String], _ added: [String], prose: ((Int, Int) -> Double?)? = nil) -> [(Int, Int)] {
        let n = removed.count, m = added.count
        guard n > 0, m > 0 else { return [] }
        let rp = removed.map(BigramProfile.init)
        let ap = added.map(BigramProfile.init)
        /// Similarity and the bar it has to clear.
        func rate(_ i: Int, _ j: Int) -> (Double, Double) {
            if let s = prose?(i, j) { return (s, ProseIndex.pairThreshold) }
            return (rp[i].similarity(to: ap[j]), threshold)
        }

        if n * m > fullSearchLimit {
            return (0..<min(n, m)).compactMap { i in
                let (sim, bar) = rate(i, i)
                return sim >= bar ? (i, i) : nil
            }
        }
        if n == 1 && m == 1 && prose?(0, 0) == nil {
            // A one-for-one replacement is always shown as a modification
            // (unless both are paragraphs about different things).
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
                let (sim, bar) = rate(i - 1, j - 1)
                if sim >= bar {
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
