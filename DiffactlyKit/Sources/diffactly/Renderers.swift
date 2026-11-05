import Foundation
import DiffactlyCore

struct RenderContext {
    let result: DiffResult
    let leftText: String
    let rightText: String
    let leftLabel: String
    let rightLabel: String
    let style: Style
    /// nil = show every line.
    let context: Int?
    let width: Int
}

// MARK: - Shared layout

/// A visual row of the split view: removed/added runs are zipped side by side.
struct VisualRow {
    var left: DiffRow?
    var right: DiffRow?
    var isChange: Bool { (left?.isChange ?? false) || (right?.isChange ?? false) || left == nil || right == nil }
}

func visualRows(_ rows: [DiffRow]) -> [VisualRow] {
    var out: [VisualRow] = []
    var i = 0
    while i < rows.count {
        let row = rows[i]
        if row.kind == .unchanged || row.kind == .modified {
            out.append(VisualRow(left: row, right: row))
            i += 1
            continue
        }
        var lefts: [DiffRow] = [], rights: [DiffRow] = []
        while i < rows.count, rows[i].kind == .removed || rows[i].kind == .added {
            if rows[i].kind == .removed { lefts.append(rows[i]) } else { rights.append(rows[i]) }
            i += 1
        }
        for k in 0..<max(lefts.count, rights.count) {
            out.append(VisualRow(left: k < lefts.count ? lefts[k] : nil, right: k < rights.count ? rights[k] : nil))
        }
    }
    return out
}

enum DisplayItem<T> {
    case item(T)
    case fold(Int)
}

/// Keeps `context` unchanged items around every change and folds the rest.
func fold<T>(_ items: [T], context: Int?, isChange: (T) -> Bool) -> [DisplayItem<T>] {
    guard let context else { return items.map { .item($0) } }
    var keep = [Bool](repeating: false, count: items.count)
    for (i, item) in items.enumerated() where isChange(item) {
        for k in max(0, i - context)...min(items.count - 1, i + context) { keep[k] = true }
    }
    var out: [DisplayItem<T>] = []
    var hidden = 0
    for (i, item) in items.enumerated() {
        if keep[i] {
            if hidden > 0 { out.append(.fold(hidden)); hidden = 0 }
            out.append(.item(item))
        } else {
            hidden += 1
        }
    }
    if hidden > 0 { out.append(.fold(hidden)) }
    return out
}

private func moveNote(_ result: DiffResult, _ row: DiffRow) -> String? {
    guard let move = result.move(id: row.moveID) else { return nil }
    func span(_ r: ClosedRange<Int>) -> String { r.count == 1 ? "line \(r.lowerBound)" : "lines \(r.lowerBound)–\(r.upperBound)" }
    let edited = move.similarity < 1 ? ", edited" : ""
    return row.kind == .removed ? "⇄ moved to \(span(move.to))\(edited)" : "⇄ moved from \(span(move.from))\(edited)"
}

// MARK: - Unified

func renderUnified(_ ctx: RenderContext) -> String {
    let s = ctx.style
    let hunks = UnifiedFormatter.hunks(ctx.result, context: ctx.context)
    guard !hunks.isEmpty else { return "" }
    var out = s.header("--- \(ctx.leftLabel)") + "\n" + s.header("+++ \(ctx.rightLabel)") + "\n"
    let rowsByID = ctx.result.rows
    for hunk in hunks {
        out += s.hunk(hunk.header) + "\n"
        var previousMove: Int? = nil
        for line in hunk.lines {
            let role: Style.Role
            switch line.kind {
            case .context: role = .plain
            case .removed: role = line.moveID != nil ? .moved : .removed
            case .added: role = line.moveID != nil ? .moved : .added
            }
            let prefix = line.kind == .context ? " " : (line.kind == .removed ? "-" : "+")
            var body = s.paint(prefix, role: role)
            for seg in line.segments {
                body += s.paint(seg.text, role: role, emphasis: seg.isChanged && role != .plain && s.enabled)
            }
            if s.enabled, let id = line.moveID, id != previousMove, let note = moveNote(ctx.result, rowsByID[line.rowID]) {
                body += "  " + s.dim(note)
            }
            previousMove = line.moveID
            out += body + "\n"
            if line.missingNewline { out += s.dim("\\ No newline at end of file") + "\n" }
        }
    }
    return out
}

// MARK: - Split

func renderSplit(_ ctx: RenderContext) -> String {
    let s = ctx.style
    let result = ctx.result
    let maxLine = max(result.stats.leftLineCount, result.stats.rightLineCount, 1)
    let numberWidth = String(maxLine).count
    let column = max(20, (ctx.width - 3) / 2)
    let gutter = numberWidth + 3
    let textWidth = max(8, column - gutter)

    func cell(_ row: DiffRow?, side: RowKind) -> [String] {
        guard let row else { return [String(repeating: " ", count: column)] }
        let line = side == .removed ? row.left : row.right
        guard let line else { return [String(repeating: " ", count: column)] }
        let role: Style.Role
        let marker: String
        switch row.kind {
        case .unchanged: role = .plain; marker = " "
        case .modified: role = side == .removed ? .removed : .added; marker = "~"
        case .removed: role = row.moveID != nil ? .moved : .removed; marker = row.moveID != nil ? "⇄" : "-"
        case .added: role = row.moveID != nil ? .moved : .added; marker = row.moveID != nil ? "⇄" : "+"
        }
        let emphasise = row.kind == .modified || row.moveID != nil
        let runs = line.segments.map { StyledRun(text: $0.text, emphasis: emphasise && $0.isChanged) }
        let wrapped = wrap(runs, width: textWidth)
        return wrapped.enumerated().map { index, parts in
            let number = index == 0 ? leftPad(String(line.number), to: numberWidth) : String(repeating: " ", count: numberWidth)
            let mark = index == 0 ? s.paint(marker, role: role) : " "
            let used = parts.reduce(0) { $0 + displayWidth($1.text) }
            let text = parts.map { run -> String in
                if emphasise { return run.emphasis ? s.paint(run.text, role: role, emphasis: s.enabled) : (row.kind == .modified ? run.text : s.paint(run.text, role: role)) }
                return s.paint(run.text, role: role)
            }.joined()
            return s.dim(number) + " " + mark + " " + text + String(repeating: " ", count: max(0, textWidth - used))
        }
    }

    var out = ""
    out += s.bold(pad(" " + ctx.leftLabel, to: column)) + " │ " + s.bold(ctx.rightLabel) + "\n"
    out += String(repeating: "─", count: column) + "─┼─" + String(repeating: "─", count: column) + "\n"
    let items = fold(visualRows(result.rows), context: ctx.context, isChange: \.isChange)
    for item in items {
        switch item {
        case .fold(let n):
            let label = "⋯ \(n) unchanged line\(n == 1 ? "" : "s") ⋯"
            out += s.dim(pad(leftPad(label, to: (column + displayWidth(label)) / 2), to: column)) + s.dim(" │ ") + "\n"
        case .item(let v):
            let l = cell(v.left, side: .removed), r = cell(v.right, side: .added)
            let blank = String(repeating: " ", count: column)
            for k in 0..<max(l.count, r.count) {
                out += (k < l.count ? l[k] : blank) + s.dim(" │ ") + (k < r.count ? r[k] : "") + "\n"
            }
        }
    }
    if result.isIdentical { out += s.dim("  No differences.") + "\n" }
    return out
}

// MARK: - Inline (word-diff style)

func renderInline(_ ctx: RenderContext) -> String {
    let s = ctx.style
    let result = ctx.result
    let numberWidth = String(max(result.stats.leftLineCount, result.stats.rightLineCount, 1)).count
    var out = s.header("--- \(ctx.leftLabel)") + "\n" + s.header("+++ \(ctx.rightLabel)") + "\n"

    func removed(_ t: String) -> String { s.enabled ? s.removedEmphasis(t) : "[-\(t)-]" }
    func added(_ t: String) -> String { s.enabled ? s.addedEmphasis(t) : "{+\(t)+}" }

    for item in fold(result.rows, context: ctx.context, isChange: \.isChange) {
        switch item {
        case .fold(let n):
            out += s.dim(String(repeating: " ", count: numberWidth) + "  ⋯ \(n) unchanged line\(n == 1 ? "" : "s")") + "\n"
        case .item(let row):
            let number = row.right?.number ?? row.left?.number ?? 0
            let gutter = s.dim(leftPad(String(number), to: numberWidth) + " │") + " "
            switch row.kind {
            case .unchanged:
                out += gutter + (row.right?.text ?? "") + "\n"
            case .removed:
                let note = moveNote(result, row).map { "  " + s.dim($0) } ?? ""
                out += s.dim(leftPad(String(row.left!.number), to: numberWidth) + " │") + " " + removed(row.left!.text) + note + "\n"
            case .added:
                let note = moveNote(result, row).map { "  " + s.dim($0) } ?? ""
                out += gutter + added(row.right!.text) + note + "\n"
            case .modified:
                let changes = DiffEngine.inlineChanges(row.left!.text, row.right!.text, options: result.options)
                let body = changes.map { c -> String in
                    switch c.kind {
                    case .equal: return c.text
                    case .removed: return removed(c.text)
                    case .added: return added(c.text)
                    }
                }.joined()
                out += gutter + body + "\n"
            }
        }
    }
    return out
}

// MARK: - Stats & graphs

private func percent(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }

private func bar(_ fraction: Double, width: Int, style: Style, role: Style.Role = .plain) -> String {
    let filled = Int((max(0, min(1, fraction)) * Double(width)).rounded())
    return style.paint(String(repeating: "█", count: filled), role: role) + style.dim(String(repeating: "░", count: width - filled))
}

func renderStats(_ ctx: RenderContext, graph: Bool) -> String {
    let s = ctx.style
    let st = ctx.result.stats
    var out = s.bold(" \(ctx.leftLabel)  →  \(ctx.rightLabel)") + "\n\n"
    let label = { (t: String) in s.dim(pad(" " + t, to: 14)) }
    out += label("Similarity") + pad(percent(st.similarity), to: 8) + bar(st.similarity, width: 30, style: s, role: .added) + "\n"
    out += label("Lines") + [
        s.added("+\(st.addedLines) added"),
        s.removed("−\(st.removedLines) removed"),
        s.modifiedMark("~\(st.modifiedLines) modified"),
        s.moved("⇄\(st.movedLines) moved"),
        s.dim("=\(st.unchangedLines) unchanged"),
    ].joined(separator: "  ") + "\n"
    out += label("Words") + s.added("+\(st.addedWords)") + " / " + s.removed("−\(st.removedWords)") + "\n"
    out += label("Characters") + s.added("+\(st.addedCharacters)") + " / " + s.removed("−\(st.removedCharacters)") + "\n"
    out += label("Changes") + "\(ctx.result.hunks.count) hunk\(ctx.result.hunks.count == 1 ? "" : "s")"
        + (ctx.result.moves.isEmpty ? "" : ", \(ctx.result.moves.count) moved block\(ctx.result.moves.count == 1 ? "" : "s")") + "\n"
    out += label("Size") + "\(st.leftLineCount) → \(st.rightLineCount) lines\n"
    var notes: [String] = []
    if st.lineEndingsDiffer { notes.append("line endings differ (CRLF vs LF)") }
    if st.trailingNewlineDiffers { notes.append("newline at end of file differs") }
    if !notes.isEmpty { out += label("Notes") + notes.joined(separator: "; ") + "\n" }
    if graph { out += "\n" + renderGraphs(ctx) }
    return out
}

func renderGraphs(_ ctx: RenderContext) -> String {
    let s = ctx.style
    let result = ctx.result
    let width = max(24, min(60, ctx.width - 24))
    var out = ""
    let label = { (t: String) in s.dim(pad(" " + t, to: 14)) }

    // Composition: one stacked bar of every line by category.
    let slices = DiffInsights.composition(result)
    let total = max(1, slices.reduce(0) { $0 + $1.lines })
    var stacked = ""
    var used = 0
    for (index, slice) in slices.enumerated() {
        var cells = Int((Double(slice.lines) / Double(total) * Double(width)).rounded())
        if slice.lines > 0 { cells = max(1, cells) }
        if index == slices.count - 1 { cells = max(0, width - used) } else { cells = min(cells, width - used) }
        used += cells
        let glyph: String
        switch slice.category {
        case .unchanged: glyph = s.enabled ? s.dim(String(repeating: "░", count: cells)) : String(repeating: "·", count: cells)
        case .modified: glyph = s.enabled ? s.modifiedMark(String(repeating: "█", count: cells)) : String(repeating: "~", count: cells)
        case .removed: glyph = s.enabled ? s.removed(String(repeating: "█", count: cells)) : String(repeating: "-", count: cells)
        case .added: glyph = s.enabled ? s.added(String(repeating: "█", count: cells)) : String(repeating: "+", count: cells)
        case .moved: glyph = s.enabled ? s.moved(String(repeating: "█", count: cells)) : String(repeating: ">", count: cells)
        }
        stacked += glyph
    }
    out += label("Composition") + stacked + "\n"
    out += String(repeating: " ", count: 14) + s.dim("unchanged") + "  " + s.modifiedMark("modified") + "  "
        + s.removed("removed") + "  " + s.added("added") + "  " + s.moved("moved") + "\n\n"

    // Change map: where in the document the changes are.
    let buckets = DiffInsights.changeMap(result, buckets: width)
    let peak = max(1, buckets.map(\.total).max() ?? 1)
    let levels = Array("▁▂▃▄▅▆▇█")
    var spark = ""
    for b in buckets {
        guard b.total > 0 else { spark += s.dim("·"); continue }
        let level = levels[min(levels.count - 1, Int((Double(b.total) / Double(peak) * Double(levels.count - 1)).rounded(.up)))]
        let dominant = [(b.removed, Style.Role.removed), (b.added, .added), (b.moved, .moved)].max { $0.0 < $1.0 }!
        let glyph = String(level)
        if b.modified >= dominant.0 { spark += s.modifiedMark(glyph) } else { spark += s.paint(glyph, role: dominant.1) }
    }
    out += label("Change map") + spark + "\n"
    let first = "line 1", last = "line \(max(result.stats.leftLineCount, result.stats.rightLineCount))"
    out += String(repeating: " ", count: 14) + s.dim(first + String(repeating: " ", count: max(1, buckets.count - first.count - last.count)) + last) + "\n\n"

    // Word shifts: words whose frequency changed most.
    let shifts = DiffInsights.wordShifts(left: ctx.leftText, right: ctx.rightText, limit: 8)
    if shifts.isEmpty {
        out += label("Word shifts") + s.dim("no word frequency changes") + "\n"
    } else {
        out += label("Word shifts") + "\n"
        let wordWidth = min(18, shifts.map { displayWidth($0.word) }.max() ?? 4)
        let maxDelta = max(1, shifts.map { abs($0.delta) }.max() ?? 1)
        for shift in shifts {
            let cells = max(1, Int(Double(abs(shift.delta)) / Double(maxDelta) * 24))
            let word = String(shift.word.prefix(18))
            let delta = shift.delta > 0 ? "+\(shift.delta)" : "−\(abs(shift.delta))"
            let role: Style.Role = shift.delta > 0 ? .added : .removed
            out += "   " + pad(word, to: wordWidth) + "  " + s.paint(leftPad(delta, to: 4), role: role) + "  "
                + s.paint(String(repeating: s.enabled ? "█" : (shift.delta > 0 ? "+" : "-"), count: cells), role: role)
                + "  " + s.dim("\(shift.leftCount) → \(shift.rightCount)") + "\n"
        }
    }
    return out
}

// MARK: - JSON

private struct JSONReport: Encodable {
    var left: String
    var right: String
    var identical: Bool
    var options: DiffOptions
    var stats: DiffStats
    var additions: Int
    var removals: Int
    var hunks: [DiffHunk]
    var moves: [DiffMove]
    var relations: [DiffRelation]
    var rows: [DiffRow]
    var insights: Insights

    struct Insights: Encodable {
        var composition: [DiffInsights.Slice]
        var changeMap: [DiffInsights.Bucket]
        var wordShifts: [DiffInsights.WordShift]
    }
}

func renderJSON(_ ctx: RenderContext) -> String {
    let r = ctx.result
    let report = JSONReport(
        left: ctx.leftLabel, right: ctx.rightLabel, identical: r.isIdentical, options: r.options, stats: r.stats,
        additions: r.stats.additions, removals: r.stats.removals,
        hunks: r.hunks, moves: r.moves, relations: r.relations, rows: r.rows,
        insights: .init(
            composition: DiffInsights.composition(r),
            changeMap: DiffInsights.changeMap(r, buckets: 24),
            wordShifts: DiffInsights.wordShifts(left: ctx.leftText, right: ctx.rightText, limit: 20)
        )
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(report), let text = String(data: data, encoding: .utf8) else { return "{}\n" }
    return text + "\n"
}
