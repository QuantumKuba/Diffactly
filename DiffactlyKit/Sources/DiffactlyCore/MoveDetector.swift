import Foundation

/// Finds blocks of lines that were removed in one place and added in another.
///
/// * Pass 1 links runs of *identical* (normalised) lines.
/// * Pass 2 links whole removed/added blocks that are near-identical by
///   character histogram (≥ 90 %): moved and lightly edited.
/// * Pass 3 ("edited moves") seeds on a significant line that appears exactly
///   in both a removed and an added block, then grows the match up and down in
///   lockstep while the lines stay similar — catching blocks that were moved
///   *and* edited (renamed variables, rewritten loops, …).
///
/// Moved rows get inline segments relative to their counterpart, so an exact
/// move shows no emphasis and an edited move highlights what changed in transit.
enum MoveDetector {
    static let fuzzyThreshold = 0.9
    static let minBlockLines = 3
    static let maxCandidatesPerLine = 64
    static let editedLineFloor = 0.25
    static let editedLineGood = 0.5
    static let editedAverage = 0.55

    static func detect(rows: inout [DiffRow], leftKeys: [String], rightKeys: [String], inline: InlineDiffer) -> [DiffMove] {
        let removed = rows.indices.filter { rows[$0].kind == .removed }
        let added = rows.indices.filter { rows[$0].kind == .added }
        guard !removed.isEmpty, !added.isEmpty else { return [] }

        let removedKeys = removed.map { leftKeys[rows[$0].left!.number - 1] }
        let addedKeys = added.map { rightKeys[rows[$0].right!.number - 1] }
        let removedNumbers = removed.map { rows[$0].left!.number }
        let addedNumbers = added.map { rows[$0].right!.number }

        func significant(_ k: String) -> Bool {
            k.count >= 2 && k.contains { $0.isLetter || $0.isNumber }
        }
        func follows(_ numbers: [Int], _ index: Int) -> Bool {
            index > 0 && numbers[index] == numbers[index - 1] + 1
        }

        var usedRemoved = [Bool](repeating: false, count: removed.count)
        var usedAdded = [Bool](repeating: false, count: added.count)
        var addedIndex: [String: [Int]] = [:]
        for (q, k) in addedKeys.enumerated() where significant(k) {
            addedIndex[k, default: []].append(q)
        }

        var moves: [DiffMove] = []
        /// Records a move between removed[p..<p+n] and added[q..<q+m] (lines paired in order).
        func record(_ rRange: Range<Int>, _ aRange: Range<Int>, similarity: Double) {
            let id = moves.count
            for t in rRange { usedRemoved[t] = true; rows[removed[t]].moveID = id }
            for t in aRange { usedAdded[t] = true; rows[added[t]].moveID = id }
            moves.append(DiffMove(
                id: id,
                from: removedNumbers[rRange.lowerBound]...removedNumbers[rRange.upperBound - 1],
                to: addedNumbers[aRange.lowerBound]...addedNumbers[aRange.upperBound - 1],
                similarity: similarity
            ))
            annotate(rRange.map { removed[$0] }, aRange.map { added[$0] })
        }

        /// Gives moved rows inline segments relative to their counterpart line.
        func annotate(_ rRows: [Int], _ aRows: [Int]) {
            let pairs: [(Int, Int)]
            if rRows.count == aRows.count {
                pairs = Array(zip(0..<rRows.count, 0..<aRows.count))
            } else {
                pairs = LinePairing.pair(rRows.map { leftKeys[rows[$0].left!.number - 1] },
                                         aRows.map { rightKeys[rows[$0].right!.number - 1] })
            }
            for (i, j) in pairs {
                let l = rows[rRows[i]].left!.text, r = rows[aRows[j]].right!.text
                let out = inline.diff(l, r)
                rows[rRows[i]].left!.segments = out.left
                rows[aRows[j]].right!.segments = out.right
            }
        }

        // Pass 1 — exact runs.
        var p = 0
        while p < removed.count {
            guard !usedRemoved[p], let candidates = addedIndex[removedKeys[p]] else { p += 1; continue }
            var bestQ = -1, bestLength = 0, bestDistance = Int.max
            for q in candidates.prefix(maxCandidatesPerLine) where !usedAdded[q] {
                var length = 0
                while p + length < removed.count, q + length < added.count,
                      !usedRemoved[p + length], !usedAdded[q + length],
                      removedKeys[p + length] == addedKeys[q + length],
                      length == 0 || (follows(removedNumbers, p + length) && follows(addedNumbers, q + length)) {
                    length += 1
                }
                let distance = abs(rows[removed[p]].id - rows[added[q]].id)
                if length > bestLength || (length == bestLength && distance < bestDistance) {
                    bestQ = q; bestLength = length; bestDistance = distance
                }
            }
            if bestLength > 0 {
                let chars = (0..<bestLength).reduce(0) { $0 + removedKeys[p + $1].count }
                if bestLength >= minBlockLines || (bestLength == 2 && chars >= 20) || chars >= 40 {
                    record(p..<(p + bestLength), bestQ..<(bestQ + bestLength), similarity: 1)
                    p += bestLength
                    continue
                }
            }
            p += 1
        }

        // Pass 2 — near-identical whole blocks.
        var removedBlocks = blocks(removedNumbers, used: usedRemoved)
        var addedBlocks = blocks(addedNumbers, used: usedAdded)
        if !removedBlocks.isEmpty, !addedBlocks.isEmpty, removedBlocks.count * addedBlocks.count <= 10_000 {
            let addedHistograms = addedBlocks.map { CharacterHistogram($0.map { addedKeys[$0] }.joined(separator: "\n")) }
            var taken = Set<Int>()
            for rb in removedBlocks where rb.count >= minBlockLines {
                let h = CharacterHistogram(rb.map { removedKeys[$0] }.joined(separator: "\n"))
                var best: (index: Int, similarity: Double)? = nil
                for (index, ab) in addedBlocks.enumerated() where !taken.contains(index) && ab.count >= minBlockLines {
                    let sim = h.similarity(to: addedHistograms[index])
                    if sim >= fuzzyThreshold, sim > (best?.similarity ?? 0) { best = (index, sim) }
                }
                guard let best else { continue }
                taken.insert(best.index)
                record(rb, addedBlocks[best.index], similarity: best.similarity)
            }
        }

        // Pass 3 — moved and edited: seed on an exact line, extend in lockstep.
        removedBlocks = blocks(removedNumbers, used: usedRemoved)
        addedBlocks = blocks(addedNumbers, used: usedAdded)
        guard !removedBlocks.isEmpty, !addedBlocks.isEmpty else { return moves }
        var blockOfAdded = [Int: Range<Int>]()
        for b in addedBlocks { for q in b { blockOfAdded[q] = b } }
        let profilesRemoved = removedKeys.map(BigramProfile.init)
        let profilesAdded = addedKeys.map(BigramProfile.init)

        for rb in removedBlocks where rb.count >= minBlockLines {
            var best: (r: Range<Int>, a: Range<Int>, score: Double, average: Double)? = nil
            for seed in rb where !usedRemoved[seed] {
                guard significant(removedKeys[seed]), let candidates = addedIndex[removedKeys[seed]] else { continue }
                for q in candidates.prefix(maxCandidatesPerLine) where !usedAdded[q] {
                    guard let ab = blockOfAdded[q], ab.count >= minBlockLines else { continue }
                    var sims: [Double] = [1]
                    var lo = 0
                    while seed - lo - 1 >= rb.lowerBound, q - lo - 1 >= ab.lowerBound,
                          !usedRemoved[seed - lo - 1], !usedAdded[q - lo - 1] {
                        let s = profilesRemoved[seed - lo - 1].similarity(to: profilesAdded[q - lo - 1])
                        guard s >= editedLineFloor else { break }
                        sims.insert(s, at: 0)
                        lo += 1
                    }
                    var hi = 0
                    while seed + hi + 1 < rb.upperBound, q + hi + 1 < ab.upperBound,
                          !usedRemoved[seed + hi + 1], !usedAdded[q + hi + 1] {
                        let s = profilesRemoved[seed + hi + 1].similarity(to: profilesAdded[q + hi + 1])
                        guard s >= editedLineFloor else { break }
                        sims.append(s)
                        hi += 1
                    }
                    // Trim weak lines off both ends.
                    var start = 0, end = sims.count
                    while start < end, sims[start] < editedLineGood { start += 1 }
                    while end > start, sims[end - 1] < editedLineGood { end -= 1 }
                    let kept = Array(sims[start..<end])
                    guard kept.count >= minBlockLines else { continue }
                    let average = kept.reduce(0, +) / Double(kept.count)
                    let goodShare = Double(kept.filter { $0 >= editedLineGood }.count) / Double(kept.count)
                    guard average >= editedAverage, goodShare >= 0.5 else { continue }
                    let rStart = seed - lo + start, aStart = q - lo + start
                    let score = average * Double(kept.count)
                    if score > (best?.score ?? 0) {
                        best = (rStart..<(rStart + kept.count), aStart..<(aStart + kept.count), score, average)
                    }
                }
            }
            if let best { record(best.r, best.a, similarity: min(best.average, 0.99)) }
        }
        return moves
    }

    /// Maximal runs of unused, consecutively numbered lines (indices into the list).
    private static func blocks(_ numbers: [Int], used: [Bool]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var i = 0
        while i < numbers.count {
            guard !used[i] else { i += 1; continue }
            let start = i
            i += 1
            while i < numbers.count, !used[i], numbers[i] == numbers[i - 1] + 1 { i += 1 }
            out.append(start..<i)
        }
        return out
    }
}

/// Character multiset used for order-insensitive block similarity.
struct CharacterHistogram {
    private var counts: [Character: Int] = [:]
    private(set) var total = 0

    init(_ text: String) {
        for ch in text where !ch.isWhitespace {
            counts[ch, default: 0] += 1
            total += 1
        }
    }

    func similarity(to other: CharacterHistogram) -> Double {
        let sum = total + other.total
        guard sum > 0 else { return 1 }
        var difference = 0
        for (ch, c) in counts { difference += abs(c - (other.counts[ch] ?? 0)) }
        for (ch, c) in other.counts where counts[ch] == nil { difference += c }
        return 1 - Double(difference) / Double(sum)
    }
}
