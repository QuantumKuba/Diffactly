import Foundation

/// Data behind the optional Insights graphs (GUI) and `--graph` output (CLI).
public enum DiffInsights {
    public enum Category: String, CaseIterable, Codable, Sendable, Identifiable {
        case unchanged, modified, removed, added, moved
        public var id: String { rawValue }
        public var title: String { rawValue.capitalized }
    }

    /// Changes falling into one slice of the comparison, top to bottom.
    public struct Bucket: Codable, Sendable, Identifiable, Equatable {
        public var id: Int
        /// Position of the slice in the comparison, 0…1.
        public var start: Double
        public var end: Double
        public var removed = 0
        public var added = 0
        public var modified = 0
        public var moved = 0
        /// First row in the slice (to jump to it).
        public var firstRow: Int
        /// First changed row in the slice, if any.
        public var firstChangedRow: Int?

        public var total: Int { removed + added + modified + moved }
    }

    /// A word whose number of occurrences changed between the two texts.
    public struct WordShift: Codable, Sendable, Identifiable, Equatable {
        public var word: String
        public var leftCount: Int
        public var rightCount: Int
        public var delta: Int { rightCount - leftCount }
        public var id: String { word }
    }

    public struct Slice: Codable, Sendable, Identifiable, Equatable {
        public var category: Category
        public var lines: Int
        public var id: String { category.rawValue }
    }

    /// Where in the comparison the changes are, split into `bucketCount` slices.
    public static func changeMap(_ result: DiffResult, buckets bucketCount: Int = 24) -> [Bucket] {
        let rows = result.rows
        guard !rows.isEmpty else { return [] }
        let count = max(1, min(bucketCount, rows.count))
        var buckets = (0..<count).map { i in
            Bucket(id: i, start: Double(i) / Double(count), end: Double(i + 1) / Double(count),
                   firstRow: i * rows.count / count, firstChangedRow: nil)
        }
        for row in rows {
            let b = min(count - 1, row.id * count / rows.count)
            switch row.kind {
            case .unchanged: continue
            case .modified: buckets[b].modified += 1
            case .removed: if row.moveID != nil { buckets[b].moved += 1 } else { buckets[b].removed += 1 }
            case .added: if row.moveID != nil { buckets[b].moved += 1 } else { buckets[b].added += 1 }
            }
            if buckets[b].firstChangedRow == nil { buckets[b].firstChangedRow = row.id }
        }
        return buckets
    }

    /// Lines per category (moved lines counted once, on the side they left).
    public static func composition(_ result: DiffResult) -> [Slice] {
        let s = result.stats
        return [
            Slice(category: .unchanged, lines: s.unchangedLines),
            Slice(category: .modified, lines: s.modifiedLines),
            Slice(category: .removed, lines: s.removedLines),
            Slice(category: .added, lines: s.addedLines),
            Slice(category: .moved, lines: s.movedLines),
        ]
    }

    /// Words whose frequency changed the most. Case-insensitive; words shorter
    /// than `minimumLength` (and pure numbers) are skipped as noise.
    public static func wordShifts(left: String, right: String, limit: Int = 8, minimumLength: Int = 3) -> [WordShift] {
        func counts(_ text: String) -> [String: Int] {
            var out: [String: Int] = [:]
            var current = ""
            func flush() {
                if current.count >= minimumLength, !current.allSatisfy(\.isNumber) {
                    out[current.lowercased(), default: 0] += 1
                }
                current = ""
            }
            for ch in text {
                if ch.isLetter || ch.isNumber || ch == "_" || (ch == "'" && !current.isEmpty) {
                    current.append(ch)
                } else {
                    flush()
                }
            }
            flush()
            return out
        }
        let l = counts(left), r = counts(right)
        var shifts: [WordShift] = []
        for word in Set(l.keys).union(r.keys) {
            let a = l[word] ?? 0, b = r[word] ?? 0
            if a != b { shifts.append(WordShift(word: word, leftCount: a, rightCount: b)) }
        }
        shifts.sort {
            if abs($0.delta) != abs($1.delta) { return abs($0.delta) > abs($1.delta) }
            if $0.delta.signum() != $1.delta.signum() { return $0.delta > $1.delta }
            return $0.word < $1.word
        }
        return Array(shifts.prefix(limit))
    }
}

/// Text transforms that can be applied to inputs before comparing.
public enum TextTransform: String, CaseIterable, Codable, Sendable, Identifiable {
    case lowercase
    case sortLines = "sort"
    case joinLines = "join"
    case trimWhitespace = "trim"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .lowercase: return "To Lowercase"
        case .sortLines: return "Sort Lines"
        case .joinLines: return "Replace Line Breaks with Spaces"
        case .trimWhitespace: return "Trim Whitespace"
        }
    }

    public func apply(to text: String) -> String {
        switch self {
        case .lowercase:
            return text.lowercased()
        case .sortLines:
            let side = SideText(text)
            let sorted = side.lines.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return sorted.joined(separator: "\n") + (side.hasTrailingNewline ? "\n" : "")
        case .joinLines:
            let side = SideText(text)
            return side.lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " ")
        case .trimWhitespace:
            let side = SideText(text)
            return side.lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
                + (side.hasTrailingNewline ? "\n" : "")
        }
    }
}
