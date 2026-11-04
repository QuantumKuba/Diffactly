import Foundation

enum EditOp: UInt8 {
    case equal, delete, insert
}

/// A run of edits over two sequences `a` (old) and `b` (new). Ranges are half-open.
struct EditRun: Equatable {
    var op: EditOp
    var a: Range<Int>
    var b: Range<Int>
}

/// Aligns two sequences of interned token keys.
///
/// Two strategies:
/// * **Weighted alignment** (small inputs): a dynamic-programming alignment that
///   maximises the total *weight* of matched tokens and adds a bonus for every
///   token that extends a contiguous run of matches. Weighting lets meaningful
///   tokens (long lines, real words) win over filler (blank lines, lone braces,
///   single spaces), and the run bonus keeps matched blocks together instead of
///   scattering them — the main reason the result reads like a human edit.
/// * **Myers O(ND)** with linear-space bisection for large inputs, guarded by a
///   deadline so pathological inputs degrade to a coarse replace instead of hanging.
struct SequenceDiffer {
    /// Weight of matching `a[i]` with `b[j]` (only called when keys are equal).
    typealias Weight = (_ i: Int, _ j: Int) -> Double

    var weight: Weight?
    /// Bonus added per step of an ongoing contiguous match (capped).
    var runBonus: Double = 0.5
    var runBonusCap: Int = 8
    /// Use the weighted alignment when `n * m` of the trimmed middle is at most this.
    var weightedCellLimit: Int = 2_500_000
    var deadline: Date = .distantFuture

    func diff(_ a: [Int], _ b: [Int]) -> [EditRun] {
        let n = a.count, m = b.count
        var prefix = 0
        while prefix < n && prefix < m && a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < n - prefix && suffix < m - prefix && a[n - 1 - suffix] == b[m - 1 - suffix] { suffix += 1 }

        var runs: [EditRun] = []
        if prefix > 0 { runs.append(EditRun(op: .equal, a: 0..<prefix, b: 0..<prefix)) }

        let aLo = prefix, aHi = n - suffix, bLo = prefix, bHi = m - suffix
        if aLo < aHi || bLo < bHi {
            let cells = (aHi - aLo) * (bHi - bLo)
            var middle: [EditRun]? = nil
            if weight != nil, cells > 0, cells <= weightedCellLimit {
                middle = weightedAlign(a, b, aLo, aHi, bLo, bHi)
            }
            if middle == nil {
                var out: [EditRun] = []
                let myers = MyersBisect(a: a, b: b, deadline: deadline)
                myers.diff(aLo, aHi, bLo, bHi, into: &out)
                middle = out
            }
            for run in middle! { Self.append(run, to: &runs) }
        }
        if suffix > 0 { Self.append(EditRun(op: .equal, a: (n - suffix)..<n, b: (m - suffix)..<m), to: &runs) }
        return Self.canonicalize(runs)
    }

    // MARK: Weighted alignment

    private func weightedAlign(_ a: [Int], _ b: [Int], _ aLo: Int, _ aHi: Int, _ bLo: Int, _ bHi: Int) -> [EditRun]? {
        guard let weight else { return nil }
        let n = aHi - aLo, m = bHi - bLo
        if n == 0 { return [EditRun(op: .insert, a: aLo..<aLo, b: bLo..<bHi)] }
        if m == 0 { return [EditRun(op: .delete, a: aLo..<aHi, b: bLo..<bLo)] }

        let cols = m + 1
        var score = [Double](repeating: 0, count: (n + 1) * cols)
        // 0 = equal (diagonal), 1 = delete (up), 2 = insert (left)
        var dir = [UInt8](repeating: 0, count: (n + 1) * cols)
        var run = [UInt16](repeating: 0, count: (n + 1) * cols)
        for i in 1...n { dir[i * cols] = 1 }
        for j in 1...m { dir[j] = 2 }

        for i in 1...n {
            if i & 63 == 0, Date() > deadline { return nil }
            let ai = a[aLo + i - 1]
            let row = i * cols, prev = (i - 1) * cols
            for j in 1...m {
                let up = score[prev + j]
                let left = score[row + j - 1]
                var best: Double
                var d: UInt8
                if up >= left { best = up; d = 1 } else { best = left; d = 2 }
                var r: UInt16 = 0
                if ai == b[bLo + j - 1] {
                    let diagIndex = prev + j - 1
                    let prevRun = dir[diagIndex] == 0 && i > 1 && j > 1 ? Int(run[diagIndex]) : 0
                    let candidate = score[diagIndex]
                        + weight(aLo + i - 1, bLo + j - 1)
                        + Double(min(prevRun, runBonusCap)) * runBonus
                    if candidate >= best {
                        best = candidate
                        d = 0
                        r = UInt16(min(prevRun + 1, Int(UInt16.max)))
                    }
                }
                score[row + j] = best
                dir[row + j] = d
                run[row + j] = r
            }
        }

        // Trace back from the end.
        var reversed: [EditRun] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            let d: UInt8 = i == 0 ? 2 : (j == 0 ? 1 : dir[i * cols + j])
            switch d {
            case 0:
                Self.prepend(EditRun(op: .equal, a: (aLo + i - 1)..<(aLo + i), b: (bLo + j - 1)..<(bLo + j)), to: &reversed)
                i -= 1; j -= 1
            case 1:
                Self.prepend(EditRun(op: .delete, a: (aLo + i - 1)..<(aLo + i), b: (bLo + j)..<(bLo + j)), to: &reversed)
                i -= 1
            default:
                Self.prepend(EditRun(op: .insert, a: (aLo + i)..<(aLo + i), b: (bLo + j - 1)..<(bLo + j)), to: &reversed)
                j -= 1
            }
        }
        return reversed.reversed()
    }

    // MARK: Run bookkeeping

    static func append(_ run: EditRun, to runs: inout [EditRun]) {
        if run.a.isEmpty && run.b.isEmpty { return }
        if var last = runs.last, last.op == run.op, last.a.upperBound == run.a.lowerBound, last.b.upperBound == run.b.lowerBound {
            last.a = last.a.lowerBound..<run.a.upperBound
            last.b = last.b.lowerBound..<run.b.upperBound
            runs[runs.count - 1] = last
        } else {
            runs.append(run)
        }
    }

    /// Builds runs back-to-front (used by trace-back); the caller reverses at the end.
    private static func prepend(_ run: EditRun, to reversed: inout [EditRun]) {
        if var last = reversed.last, last.op == run.op, run.a.upperBound == last.a.lowerBound, run.b.upperBound == last.b.lowerBound {
            last.a = run.a.lowerBound..<last.a.upperBound
            last.b = run.b.lowerBound..<last.b.upperBound
            reversed[reversed.count - 1] = last
        } else {
            reversed.append(run)
        }
    }

    /// Merges every change region between two equal runs into one delete run
    /// followed by one insert run, so consumers see `equal (delete? insert?) equal …`.
    static func canonicalize(_ runs: [EditRun]) -> [EditRun] {
        var out: [EditRun] = []
        var i = 0
        while i < runs.count {
            if runs[i].op == .equal {
                append(runs[i], to: &out)
                i += 1
                continue
            }
            var aStart = Int.max, aEnd = Int.min, bStart = Int.max, bEnd = Int.min
            while i < runs.count, runs[i].op != .equal {
                aStart = min(aStart, runs[i].a.lowerBound); aEnd = max(aEnd, runs[i].a.upperBound)
                bStart = min(bStart, runs[i].b.lowerBound); bEnd = max(bEnd, runs[i].b.upperBound)
                i += 1
            }
            if aEnd > aStart { out.append(EditRun(op: .delete, a: aStart..<aEnd, b: bStart..<bStart)) }
            if bEnd > bStart { out.append(EditRun(op: .insert, a: aEnd..<aEnd, b: bStart..<bEnd)) }
        }
        return out
    }
}

/// Myers' O(ND) difference algorithm with the linear-space "middle snake" bisection
/// (the variant popularised by diff-match-patch).
private final class MyersBisect {
    let a: [Int]
    let b: [Int]
    let deadline: Date

    init(a: [Int], b: [Int], deadline: Date) {
        self.a = a
        self.b = b
        self.deadline = deadline
    }

    func diff(_ aLo: Int, _ aHi: Int, _ bLo: Int, _ bHi: Int, into out: inout [EditRun]) {
        var aLo = aLo, aHi = aHi, bLo = bLo, bHi = bHi
        // Common prefix / suffix.
        var start = 0
        while aLo + start < aHi, bLo + start < bHi, a[aLo + start] == b[bLo + start] { start += 1 }
        if start > 0 {
            SequenceDiffer.append(EditRun(op: .equal, a: aLo..<(aLo + start), b: bLo..<(bLo + start)), to: &out)
            aLo += start; bLo += start
        }
        var end = 0
        while aHi - end > aLo, bHi - end > bLo, a[aHi - 1 - end] == b[bHi - 1 - end] { end += 1 }
        let suffixA = (aHi - end)..<aHi, suffixB = (bHi - end)..<bHi
        aHi -= end; bHi -= end

        if aLo == aHi {
            SequenceDiffer.append(EditRun(op: .insert, a: aLo..<aLo, b: bLo..<bHi), to: &out)
        } else if bLo == bHi {
            SequenceDiffer.append(EditRun(op: .delete, a: aLo..<aHi, b: bLo..<bLo), to: &out)
        } else if let (x, y) = bisect(aLo, aHi, bLo, bHi) {
            diff(aLo, x, bLo, y, into: &out)
            diff(x, aHi, y, bHi, into: &out)
        } else {
            SequenceDiffer.append(EditRun(op: .delete, a: aLo..<aHi, b: bLo..<bLo), to: &out)
            SequenceDiffer.append(EditRun(op: .insert, a: aHi..<aHi, b: bLo..<bHi), to: &out)
        }

        if end > 0 { SequenceDiffer.append(EditRun(op: .equal, a: suffixA, b: suffixB), to: &out) }
    }

    /// Finds the middle snake; returns the absolute split point, or nil when the
    /// sequences share nothing (or the deadline passed).
    private func bisect(_ aLo: Int, _ aHi: Int, _ bLo: Int, _ bHi: Int) -> (Int, Int)? {
        let n = aHi - aLo, m = bHi - bLo
        let maxD = (n + m + 1) / 2
        let vOffset = maxD
        let vLength = 2 * maxD + 2
        var v1 = [Int](repeating: -1, count: vLength)
        var v2 = [Int](repeating: -1, count: vLength)
        v1[vOffset + 1] = 0
        v2[vOffset + 1] = 0
        let delta = n - m
        let front = delta % 2 != 0
        var k1start = 0, k1end = 0, k2start = 0, k2end = 0

        for d in 0..<maxD {
            if d & 15 == 0, Date() > deadline { return nil }

            var k1 = -d + k1start
            while k1 <= d - k1end {
                let k1Offset = vOffset + k1
                var x1: Int
                if k1 == -d || (k1 != d && v1[k1Offset - 1] < v1[k1Offset + 1]) {
                    x1 = v1[k1Offset + 1]
                } else {
                    x1 = v1[k1Offset - 1] + 1
                }
                var y1 = x1 - k1
                while x1 < n, y1 < m, a[aLo + x1] == b[bLo + y1] { x1 += 1; y1 += 1 }
                v1[k1Offset] = x1
                if x1 > n {
                    k1end += 2
                } else if y1 > m {
                    k1start += 2
                } else if front {
                    let k2Offset = vOffset + delta - k1
                    if k2Offset >= 0, k2Offset < vLength, v2[k2Offset] != -1 {
                        let x2 = n - v2[k2Offset]
                        if x1 >= x2 { return (aLo + x1, bLo + y1) }
                    }
                }
                k1 += 2
            }

            var k2 = -d + k2start
            while k2 <= d - k2end {
                let k2Offset = vOffset + k2
                var x2: Int
                if k2 == -d || (k2 != d && v2[k2Offset - 1] < v2[k2Offset + 1]) {
                    x2 = v2[k2Offset + 1]
                } else {
                    x2 = v2[k2Offset - 1] + 1
                }
                var y2 = x2 - k2
                while x2 < n, y2 < m, a[aLo + n - x2 - 1] == b[bLo + m - y2 - 1] { x2 += 1; y2 += 1 }
                v2[k2Offset] = x2
                if x2 > n {
                    k2end += 2
                } else if y2 > m {
                    k2start += 2
                } else if !front {
                    let k1Offset = vOffset + delta - k2
                    if k1Offset >= 0, k1Offset < vLength, v1[k1Offset] != -1 {
                        let x1 = v1[k1Offset]
                        let y1 = vOffset + x1 - k1Offset
                        if x1 >= n - x2 { return (aLo + x1, bLo + y1) }
                    }
                }
                k2 += 2
            }
        }
        return nil
    }
}

/// Maps strings to dense integer keys so sequences can be compared as `[Int]`.
struct Interner {
    private var table: [String: Int] = [:]
    private(set) var strings: [String] = []

    mutating func key(_ s: String) -> Int {
        if let k = table[s] { return k }
        let k = strings.count
        table[s] = k
        strings.append(s)
        return k
    }
}
