import Foundation

/// A piece of an inline diff. Equal pieces carry both sides' text because, with
/// case/quote/dash folding, "equal" text can still differ cosmetically.
struct Piece: Equatable {
    var op: EditOp
    var left: String
    var right: String
    var ignored = false

    static func equal(_ l: String, _ r: String, ignored: Bool = false) -> Piece { Piece(op: .equal, left: l, right: r, ignored: ignored) }
    static func delete(_ s: String) -> Piece { Piece(op: .delete, left: s, right: "") }
    static func insert(_ s: String) -> Piece { Piece(op: .insert, left: "", right: s) }
}

/// Computes the differences *inside* a pair of aligned lines.
struct InlineDiffer {
    let normalizer: Normalizer
    let level: DiffLevel
    var deadline: Date = .distantFuture

    struct Output {
        var left: [DiffSegment]
        var right: [DiffSegment]
        var hasVisibleChange: Bool
        var hasIgnoredDifferences: Bool
    }

    func diff(_ l: String, _ r: String) -> Output {
        if l == r {
            return Output(left: [DiffSegment(l, changed: false)], right: [DiffSegment(r, changed: false)], hasVisibleChange: false, hasIgnoredDifferences: false)
        }
        var pieces: [Piece]
        if l.isEmpty || r.isEmpty {
            pieces = [.delete(l), .insert(r)]
        } else {
            switch level {
            case .character: pieces = characterPieces(l, r)
            case .word: pieces = wordPieces(l, r)
            case .smart: pieces = smartPieces(l, r)
            }
        }
        pieces = applyIgnoreRules(InlineDiffer.normalize(pieces))
        return InlineDiffer.output(pieces)
    }

    // MARK: Levels

    func characterPieces(_ l: String, _ r: String) -> [Piece] {
        var pieces = tokenPieces(Tokenizer.characters(l), Tokenizer.characters(r)) { token in
            token.allSatisfy(\.isWhitespace) ? 0.5 : 1
        }
        pieces = InlineDiffer.cleanupSemantic(pieces)
        return InlineDiffer.shiftToBoundaries(pieces)
    }

    func wordPieces(_ l: String, _ r: String) -> [Piece] {
        let pieces = tokenPieces(Tokenizer.words(l), Tokenizer.words(r), weight: InlineDiffer.wordWeight)
        return InlineDiffer.absorbWhitespaceGaps(pieces)
    }

    /// Word diff first, then each replaced region that is *mostly the same text*
    /// is re-diffed at character level: typo fixes and suffix changes highlight
    /// only the letters that changed, rewrites keep whole-word highlights.
    func smartPieces(_ l: String, _ r: String) -> [Piece] {
        let words = InlineDiffer.normalize(wordPieces(l, r))
        var out: [Piece] = []
        var i = 0
        while i < words.count {
            if words[i].op == .equal { out.append(words[i]); i += 1; continue }
            var removed = "", inserted = ""
            while i < words.count, words[i].op != .equal {
                removed += words[i].left
                inserted += words[i].right
                i += 1
            }
            if !removed.isEmpty, !inserted.isEmpty, removed.count + inserted.count <= 120 {
                let chars = InlineDiffer.normalize(characterPieces(removed, inserted))
                let shared = chars.filter { $0.op == .equal }.reduce(0) { $0 + $1.left.count }
                let ratio = 2 * Double(shared) / Double(removed.count + inserted.count)
                if ratio >= 0.6 {
                    out.append(contentsOf: chars)
                    continue
                }
            }
            if !removed.isEmpty { out.append(.delete(removed)) }
            if !inserted.isEmpty { out.append(.insert(inserted)) }
        }
        return InlineDiffer.shiftToBoundaries(InlineDiffer.normalize(out))
    }

    private static func wordWeight(_ token: String) -> Double {
        guard let first = token.first else { return 0.1 }
        switch Tokenizer.kind(of: first) {
        case .space: return 0.2
        case .symbol: return 0.6
        case .word: return 1 + log(1 + Double(token.count))
        }
    }

    private func tokenPieces(_ lt: [String], _ rt: [String], weight: @escaping (String) -> Double) -> [Piece] {
        var interner = Interner()
        let a = lt.map { interner.key(normalizer.tokenKey($0)) }
        let b = rt.map { interner.key(normalizer.tokenKey($0)) }
        var differ = SequenceDiffer()
        differ.weight = { i, _ in weight(lt[i]) }
        differ.runBonus = 0.3
        differ.runBonusCap = 6
        differ.weightedCellLimit = 250_000
        differ.deadline = deadline
        return differ.diff(a, b).map { run in
            switch run.op {
            case .equal: return .equal(lt[run.a].joined(), rt[run.b].joined())
            case .delete: return .delete(lt[run.a].joined())
            case .insert: return .insert(rt[run.b].joined())
            }
        }
    }

    // MARK: Ignore rules

    /// Collapses change regions whose only differences are ignored content into
    /// (flagged) equal pieces.
    func applyIgnoreRules(_ pieces: [Piece]) -> [Piece] {
        var out: [Piece] = []
        var i = 0
        while i < pieces.count {
            if pieces[i].op == .equal {
                var p = pieces[i]
                if p.left != p.right { p.ignored = true }
                out.append(p)
                i += 1
                continue
            }
            let start = i
            var removed = "", inserted = ""
            while i < pieces.count, pieces[i].op != .equal {
                removed += pieces[i].left
                inserted += pieces[i].right
                i += 1
            }
            if normalizer.contentKey(removed) == normalizer.contentKey(inserted) {
                out.append(.equal(removed, inserted, ignored: true))
            } else {
                out.append(contentsOf: pieces[start..<i])
            }
        }
        return InlineDiffer.normalize(out)
    }

    // MARK: Piece utilities

    /// Merges adjacent equal pieces and turns every change region into at most
    /// one delete followed by one insert.
    static func normalize(_ pieces: [Piece]) -> [Piece] {
        var out: [Piece] = []
        var i = 0
        while i < pieces.count {
            if pieces[i].op == .equal {
                var eq = pieces[i]
                i += 1
                while i < pieces.count, pieces[i].op == .equal {
                    eq.left += pieces[i].left
                    eq.right += pieces[i].right
                    eq.ignored = eq.ignored || pieces[i].ignored
                    i += 1
                }
                if !(eq.left.isEmpty && eq.right.isEmpty) { out.append(eq) }
                continue
            }
            var removed = "", inserted = ""
            while i < pieces.count, pieces[i].op != .equal {
                removed += pieces[i].left
                inserted += pieces[i].right
                i += 1
            }
            if !removed.isEmpty { out.append(.delete(removed)) }
            if !inserted.isEmpty { out.append(.insert(inserted)) }
        }
        return out
    }

    /// Semantic cleanup in the spirit of diff-match-patch: an unchanged island that
    /// is no longer than the edits on *both* sides of it is noise — fold it into
    /// the edit so the reader sees one coherent change.
    static func cleanupSemantic(_ input: [Piece]) -> [Piece] {
        var pieces = normalize(input)
        var changed = true
        var passes = 0
        while changed && passes < 32 {
            changed = false
            passes += 1
            var out: [Piece] = []
            for idx in pieces.indices {
                let p = pieces[idx]
                guard p.op == .equal, idx > 0, idx < pieces.count - 1 else { out.append(p); continue }
                let before = changeLengths(pieces, from: idx - 1, step: -1)
                let after = changeLengths(pieces, from: idx + 1, step: 1)
                let length = max(p.left.count, p.right.count)
                if before.max > 0, after.max > 0, length <= before.max, length <= after.max {
                    out.append(.delete(p.left))
                    out.append(.insert(p.right))
                    changed = true
                } else {
                    out.append(p)
                }
            }
            pieces = normalize(out)
        }
        return pieces
    }

    private static func changeLengths(_ pieces: [Piece], from start: Int, step: Int) -> (max: Int, sum: Int) {
        var deleted = 0, inserted = 0
        var i = start
        while i >= 0, i < pieces.count, pieces[i].op != .equal {
            if pieces[i].op == .delete { deleted += pieces[i].left.count } else { inserted += pieces[i].right.count }
            i += step
        }
        return (max(deleted, inserted), deleted + inserted)
    }

    /// Short whitespace between two edited words belongs to the edit
    /// ("quick brown" → "fast red" reads as one change, not two).
    static func absorbWhitespaceGaps(_ input: [Piece]) -> [Piece] {
        let pieces = normalize(input)
        var out: [Piece] = []
        for idx in pieces.indices {
            let p = pieces[idx]
            if p.op == .equal, idx > 0, idx < pieces.count - 1,
               p.left == p.right, p.left.count <= 2, p.left.allSatisfy({ $0.isWhitespace && !$0.isNewline }) {
                out.append(.delete(p.left))
                out.append(.insert(p.right))
            } else {
                out.append(p)
            }
        }
        return normalize(out)
    }

    /// Slides pure insertions/deletions sideways (without changing what they
    /// add or remove) so their edges fall on word boundaries — the
    /// "lossless" cleanup from diff-match-patch.
    static func shiftToBoundaries(_ input: [Piece]) -> [Piece] {
        var pieces = normalize(input)
        guard pieces.count >= 3 else { return pieces }
        var idx = 1
        while idx < pieces.count - 1 {
            let prev = pieces[idx - 1], cur = pieces[idx], next = pieces[idx + 1]
            guard prev.op == .equal, next.op == .equal, cur.op != .equal,
                  prev.left == prev.right, next.left == next.right, !prev.ignored, !next.ignored else { idx += 1; continue }
            var eq1 = Array(prev.left), edit = Array(cur.op == .delete ? cur.left : cur.right), eq2 = Array(next.left)
            // Shift as far left as possible.
            var common = 0
            while common < eq1.count, common < edit.count, eq1[eq1.count - 1 - common] == edit[edit.count - 1 - common] { common += 1 }
            if common > 0 {
                let moved = Array(edit[(edit.count - common)...])
                eq1.removeLast(common)
                edit = moved + edit[..<(edit.count - common)]
                eq2 = moved + eq2
            }
            var best = (eq1, edit, eq2)
            var bestScore = boundaryScore(eq1, edit) + boundaryScore(edit, eq2)
            while let e = edit.first, let f = eq2.first, e == f {
                eq1.append(e)
                edit.removeFirst()
                edit.append(f)
                eq2.removeFirst()
                let score = boundaryScore(eq1, edit) + boundaryScore(edit, eq2)
                if score >= bestScore {
                    bestScore = score
                    best = (eq1, edit, eq2)
                }
            }
            let (b1, bEdit, b2) = best
            pieces[idx - 1] = .equal(String(b1), String(b1))
            pieces[idx] = cur.op == .delete ? .delete(String(bEdit)) : .insert(String(bEdit))
            pieces[idx + 1] = .equal(String(b2), String(b2))
            idx += 1
        }
        return normalize(pieces)
    }

    /// How natural a cut between `one` and `two` is: 6 at the edge of the text,
    /// down to 0 inside a word.
    private static func boundaryScore(_ one: [Character], _ two: [Character]) -> Int {
        guard let c1 = one.last, let c2 = two.first else { return 6 }
        let nonAlnum1 = !(c1.isLetter || c1.isNumber)
        let nonAlnum2 = !(c2.isLetter || c2.isNumber)
        let space1 = nonAlnum1 && c1.isWhitespace
        let space2 = nonAlnum2 && c2.isWhitespace
        let lineBreak1 = space1 && c1.isNewline
        let lineBreak2 = space2 && c2.isNewline
        if lineBreak1 || lineBreak2 { return 4 }
        if nonAlnum1 && !space1 && space2 { return 3 }   // end of sentence/clause
        if space1 || space2 { return 2 }
        if nonAlnum1 || nonAlnum2 { return 1 }
        return 0
    }

    static func output(_ pieces: [Piece]) -> Output {
        var left: [DiffSegment] = [], right: [DiffSegment] = []
        var visible = false, ignored = false
        func push(_ text: String, _ changed: Bool, into segments: inout [DiffSegment]) {
            guard !text.isEmpty else { return }
            if let last = segments.last, last.isChanged == changed {
                segments[segments.count - 1].text += text
            } else {
                segments.append(DiffSegment(text, changed: changed))
            }
        }
        for p in pieces {
            switch p.op {
            case .equal:
                if p.ignored { ignored = true }
                push(p.left, false, into: &left)
                push(p.right, false, into: &right)
            case .delete:
                visible = true
                push(p.left, true, into: &left)
            case .insert:
                visible = true
                push(p.right, true, into: &right)
            }
        }
        return Output(left: left, right: right, hasVisibleChange: visible, hasIgnoredDifferences: ignored)
    }
}
