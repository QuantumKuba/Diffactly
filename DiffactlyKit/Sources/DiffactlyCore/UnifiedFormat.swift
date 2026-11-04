import Foundation

/// Unified (`diff -u` / git style) layout of a comparison.
public struct UnifiedHunk: Sendable, Equatable {
    public enum LineKind: Sendable, Equatable { case context, removed, added }

    public struct Line: Sendable, Equatable {
        public var kind: LineKind
        public var text: String
        public var segments: [DiffSegment]
        public var leftNumber: Int?
        public var rightNumber: Int?
        public var rowID: Int
        public var moveID: Int?
        /// Emit "\ No newline at end of file" after this line.
        public var missingNewline: Bool
    }

    public var leftStart: Int
    public var leftCount: Int
    public var rightStart: Int
    public var rightCount: Int
    public var lines: [Line]

    public var header: String {
        func range(_ start: Int, _ count: Int) -> String { count == 1 ? "\(start)" : "\(start),\(count)" }
        return "@@ -\(range(leftStart, leftCount)) +\(range(rightStart, rightCount)) @@"
    }
}

public enum UnifiedFormatter {
    /// Splits a comparison into unified hunks with `context` lines around each change.
    /// Pass `context: nil` for a single hunk covering everything.
    public static func hunks(_ result: DiffResult, context: Int? = 3) -> [UnifiedHunk] {
        var lines: [UnifiedHunk.Line] = []
        var leftBefore: [Int] = []   // left lines emitted before each patch line
        var rightBefore: [Int] = []
        var leftSeen = 0, rightSeen = 0
        let leftLast = result.stats.leftLineCount, rightLast = result.stats.rightLineCount

        func emit(_ line: UnifiedHunk.Line) {
            leftBefore.append(leftSeen)
            rightBefore.append(rightSeen)
            if line.kind != .added { leftSeen += 1 }
            if line.kind != .removed { rightSeen += 1 }
            lines.append(line)
        }

        let rows = result.rows
        var i = 0
        while i < rows.count {
            let row = rows[i]
            if !row.isChange {
                let l = row.left!, r = row.right!
                let missing = (l.number == leftLast && !result.leftHasTrailingNewline)
                emit(.init(kind: .context, text: l.text, segments: l.segments, leftNumber: l.number, rightNumber: r.number,
                           rowID: row.id, moveID: nil, missingNewline: missing))
                i += 1
                continue
            }
            // A change run: all removals first, then all additions (git order).
            let start = i
            while i < rows.count, rows[i].isChange { i += 1 }
            for row in rows[start..<i] {
                guard let l = row.left else { continue }
                emit(.init(kind: .removed, text: l.text, segments: row.kind == .modified || row.moveID != nil ? l.segments : [DiffSegment(l.text, changed: false)],
                           leftNumber: l.number, rightNumber: nil, rowID: row.id, moveID: row.moveID,
                           missingNewline: l.number == leftLast && !result.leftHasTrailingNewline))
            }
            for row in rows[start..<i] {
                guard let r = row.right else { continue }
                emit(.init(kind: .added, text: r.text, segments: row.kind == .modified || row.moveID != nil ? r.segments : [DiffSegment(r.text, changed: false)],
                           leftNumber: nil, rightNumber: r.number, rowID: row.id, moveID: row.moveID,
                           missingNewline: r.number == rightLast && !result.rightHasTrailingNewline))
            }
        }

        guard !lines.isEmpty else { return [] }
        let changeIndices = lines.indices.filter { lines[$0].kind != .context }
        guard !changeIndices.isEmpty else { return [] }

        var windows: [ClosedRange<Int>] = []
        if let context {
            for idx in changeIndices {
                let w = max(0, idx - context)...min(lines.count - 1, idx + context)
                if let last = windows.last, w.lowerBound <= last.upperBound + 1 {
                    windows[windows.count - 1] = last.lowerBound...max(last.upperBound, w.upperBound)
                } else {
                    windows.append(w)
                }
            }
        } else {
            windows = [0...(lines.count - 1)]
        }

        return windows.map { w in
            let slice = Array(lines[w])
            let leftCount = slice.filter { $0.kind != .added }.count
            let rightCount = slice.filter { $0.kind != .removed }.count
            return UnifiedHunk(
                leftStart: leftBefore[w.lowerBound] + (leftCount > 0 ? 1 : 0), leftCount: leftCount,
                rightStart: rightBefore[w.lowerBound] + (rightCount > 0 ? 1 : 0), rightCount: rightCount,
                lines: slice
            )
        }
    }

    /// A plain unified diff that `patch` / `git apply` understand.
    public static func patch(_ result: DiffResult, leftLabel: String = "a", rightLabel: String = "b", context: Int = 3) -> String {
        let hunks = hunks(result, context: context)
        guard !hunks.isEmpty else { return "" }
        var out = "--- \(leftLabel)\n+++ \(rightLabel)\n"
        for hunk in hunks {
            out += hunk.header + "\n"
            for line in hunk.lines {
                let prefix: String
                switch line.kind {
                case .context: prefix = " "
                case .removed: prefix = "-"
                case .added: prefix = "+"
                }
                out += prefix + line.text + "\n"
                if line.missingNewline { out += "\\ No newline at end of file\n" }
            }
        }
        return out
    }
}
