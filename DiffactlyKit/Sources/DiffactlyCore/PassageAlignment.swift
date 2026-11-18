import Foundation

/// Finds where part of a passage went in a rewrite of it, so a selection made
/// in the original text can be carried over to the rewritten one.
public enum PassageAlignment {

    /// The part of `new` that corresponds to `range` of `old` (UTF-16). Words
    /// both texts share pin the edges; a change at an edge takes in the whole
    /// changed stretch. The result covers whole words, and whole sentences
    /// when the selection in `old` did. nil when nothing is left.
    public static func map(_ range: NSRange, from old: String, to new: String) -> NSRange? {
        let oldNS = old as NSString, newNS = new as NSString
        guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= oldNS.length, newNS.length > 0 else { return nil }
        let oldTokens = tokens(oldNS), newTokens = tokens(newNS)
        let partner = matches(oldTokens.map { oldNS.substring(with: $0) }, newTokens.map { newNS.substring(with: $0) })

        var start = 0
        if let i = oldTokens.firstIndex(where: { NSMaxRange($0) > range.location }) {
            if let j = partner[i] {
                start = newTokens[j].location + min(range.location - oldTokens[i].location, newTokens[j].length)
            } else if let j = (0..<i).reversed().lazy.compactMap({ partner[$0] }).first {
                start = NSMaxRange(newTokens[j])
            }
        }
        var end = newNS.length
        let last = NSMaxRange(range)
        if let i = oldTokens.lastIndex(where: { $0.location < last }) {
            if let j = partner[i] {
                end = newTokens[j].location + min(last - oldTokens[i].location, newTokens[j].length)
            } else if let j = (i + 1..<oldTokens.count).lazy.compactMap({ partner[$0] }).first {
                end = newTokens[j].location
            }
        }
        guard end > start else { return nil }

        var mapped = trimmed(wholeWords(NSRange(location: start, length: end - start), in: newNS), in: newNS)
        if mapped.length > 0, coversWholeSentences(trimmed(range, in: oldNS), in: oldNS) {
            mapped = trimmed(wholeSentences(mapped, in: newNS), in: newNS)
        }
        return mapped.length > 0 ? mapped : nil
    }

    /// `range` without whitespace at either end.
    public static func trimmed(_ range: NSRange, in text: NSString) -> NSRange {
        var start = range.location, end = NSMaxRange(range)
        while start < end, isSpace(text.character(at: start)) { start += 1 }
        while end > start, isSpace(text.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    // MARK: Tokens

    /// Words, single punctuation marks and runs of whitespace, in order.
    static func tokens(_ text: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var i = 0
        while i < text.length {
            let c = text.character(at: i)
            var j = i + 1
            if isWord(c) {
                while j < text.length, isWord(text.character(at: j)) { j += 1 }
            } else if isSpace(c) {
                while j < text.length, isSpace(text.character(at: j)) { j += 1 }
            } else if UTF16.isLeadSurrogate(c), j < text.length {
                j += 1
            }
            out.append(NSRange(location: i, length: j - i))
            i = j
        }
        return out
    }

    /// For each token of `a`, the token of `b` it lines up with (longest
    /// common subsequence), or nil when it was changed.
    static func matches(_ a: [String], _ b: [String]) -> [Int?] {
        var partner = [Int?](repeating: nil, count: a.count)
        // Shared ends first: cheap, and keeps the table small.
        var lo = 0
        while lo < a.count, lo < b.count, a[lo] == b[lo] { partner[lo] = lo; lo += 1 }
        var hiA = a.count, hiB = b.count
        while hiA > lo, hiB > lo, a[hiA - 1] == b[hiB - 1] { hiA -= 1; hiB -= 1; partner[hiA] = hiB }
        let n = hiA - lo, m = hiB - lo
        guard n > 0, m > 0 else { return partner }
        // Long rewrites: too big a table to be worth it; the shared ends are enough.
        guard n * m <= 4_000_000 else { return partner }
        var table = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[lo + i] == b[lo + j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var i = 0, j = 0
        while i < n, j < m {
            if a[lo + i] == b[lo + j] {
                // Whitespace alone is too common to anchor on.
                if !a[lo + i].allSatisfy(\.isWhitespace) { partner[lo + i] = lo + j }
                i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return partner
    }

    // MARK: Snapping

    private static func wholeWords(_ range: NSRange, in text: NSString) -> NSRange {
        var start = range.location, end = NSMaxRange(range)
        while start > 0, start < text.length, isWord(text.character(at: start - 1)), isWord(text.character(at: start)) { start -= 1 }
        while end < text.length, end > 0, isWord(text.character(at: end)), isWord(text.character(at: end - 1)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func sentences(in text: NSString) -> [NSRange] {
        var out: [NSRange] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            let core = trimmed(range, in: text)
            if core.length > 0 { out.append(core) }
        }
        return out
    }

    /// The selection starts where a sentence starts and ends where one ends.
    private static func coversWholeSentences(_ range: NSRange, in text: NSString) -> Bool {
        guard range.length > 0 else { return false }
        let all = sentences(in: text)
        return all.contains { $0.location == range.location } && all.contains { NSMaxRange($0) == NSMaxRange(range) }
    }

    private static func wholeSentences(_ range: NSRange, in text: NSString) -> NSRange {
        let touched = sentences(in: text).filter { NSIntersectionRange($0, range).length > 0 }
        guard let first = touched.first, let last = touched.last else { return range }
        let start = min(first.location, range.location), end = max(NSMaxRange(last), NSMaxRange(range))
        return NSRange(location: start, length: end - start)
    }

    private static func isWord(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return true }  // half of a pair: part of whatever it is
        return CharacterSet.alphanumerics.contains(scalar) || c == 0x27 || c == 0x2019 || c == 0x2D
    }

    private static func isSpace(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}
