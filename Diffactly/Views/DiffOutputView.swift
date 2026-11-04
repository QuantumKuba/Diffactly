import SwiftUI
import DiffactlyCore

/// Read-only, aligned comparison (side-by-side or unified).
struct DiffOutputView: View {
    @ObservedObject var document: DiffDocument
    let layout: DiffDocument.Mode
    @Environment(\.colorScheme) private var colorScheme

    private static let contextLines = 3

    var body: some View {
        let model = OutputModel(
            result: document.result, layout: layout,
            collapse: document.collapseUnchanged, expanded: document.expandedFolds,
            context: Self.contextLines
        )
        VStack(spacing: 0) {
            header
            Divider()
            if document.result.isIdentical {
                IdenticalView(document: document)
            } else {
                rows(model)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 0) {
            if layout == .split {
                sideHeader(.left)
                Divider()
                sideHeader(.right)
            } else {
                HStack(spacing: 10) {
                    fileLabel(.left)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                    fileLabel(.right)
                    Spacer()
                    removalsLabel
                    additionsLabel
                }
                .padding(.horizontal, 12)
            }
        }
        .frame(height: 30)
        .background(.bar)
    }

    private func sideHeader(_ side: DiffDocument.Side) -> some View {
        HStack {
            fileLabel(side)
            Spacer()
            if side == .left { removalsLabel } else { additionsLabel }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }

    private func fileLabel(_ side: DiffDocument.Side) -> some View {
        HStack(spacing: 6) {
            Text(side.title).font(.subheadline.weight(.semibold))
            if let name = side == .left ? document.leftName : document.rightName {
                Text(name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private var removalsLabel: some View {
        let n = document.result.stats.removals
        return Text("−\(n) removal\(n == 1 ? "" : "s")").font(.caption.monospacedDigit()).foregroundStyle(DiffPalette.removed)
    }

    private var additionsLabel: some View {
        let n = document.result.stats.additions
        return Text("+\(n) addition\(n == 1 ? "" : "s")").font(.caption.monospacedDigit()).foregroundStyle(DiffPalette.added)
    }

    // MARK: Rows

    private func rows(_ model: OutputModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView(document.wrapLines || layout == .split ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.items) { item in
                        switch item.content {
                        case .split(let left, let right):
                            SplitRowView(document: document, left: left, right: right, gutter: model.gutterWidth,
                                         dark: colorScheme == .dark, isCurrent: model.isCurrent(item, document: document))
                        case .unified(let line):
                            UnifiedRowView(document: document, line: line, gutter: model.gutterWidth,
                                           dark: colorScheme == .dark, isCurrent: model.isCurrent(item, document: document))
                        case .fold(let id, let count):
                            FoldRow(count: count) { document.expandedFolds.insert(id) }
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .onChange(of: document.focusRequest) { _, request in
                guard let request, let target = model.itemID(forRow: request.rowID) else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .center) }
            }
        }
    }
}

// MARK: - Presentation model

struct OutputModel {
    struct Item: Identifiable {
        enum Content {
            case split(DiffRow?, DiffRow?)
            case unified(UnifiedHunk.Line)
            case fold(id: Int, count: Int)
        }
        let id: String
        let content: Content
        let rowIDs: [Int]
    }

    private(set) var items: [Item] = []
    private var rowToItem: [Int: String] = [:]
    let gutterWidth: CGFloat

    init(result: DiffResult, layout: DiffDocument.Mode, collapse: Bool, expanded: Set<Int>, context: Int) {
        let maxLine = max(result.stats.leftLineCount, result.stats.rightLineCount, 1)
        gutterWidth = CGFloat(String(maxLine).count) * 7.5 + 14

        var raw: [Item] = []
        if layout == .unified {
            // Identical results never reach here (IdenticalView is shown instead).
            let all = UnifiedFormatter.hunks(result, context: nil).flatMap(\.lines)
            raw = all.map { line in
                Item(id: "u\(line.rowID)\(line.kind == .added ? "+" : (line.kind == .removed ? "-" : "="))", content: .unified(line), rowIDs: [line.rowID])
            }
        } else {
            raw = Self.zip(result.rows).map { pair in
                Item(id: "s\(pair.0?.id ?? -1)_\(pair.1?.id ?? -1)", content: .split(pair.0, pair.1),
                     rowIDs: [pair.0?.id, pair.1?.id].compactMap { $0 })
            }
        }

        func isChange(_ item: Item) -> Bool {
            switch item.content {
            case .split(let l, let r): return l == nil || r == nil || l!.isChange || r!.isChange
            case .unified(let line): return line.kind != .context
            case .fold: return false
            }
        }

        if collapse {
            var keep = [Bool](repeating: false, count: raw.count)
            for (i, item) in raw.enumerated() where isChange(item) {
                for k in max(0, i - context)...min(raw.count - 1, i + context) { keep[k] = true }
            }
            var i = 0
            while i < raw.count {
                if keep[i] { items.append(raw[i]); i += 1; continue }
                let start = i
                while i < raw.count, !keep[i] { i += 1 }
                if expanded.contains(start) {
                    items.append(contentsOf: raw[start..<i])
                } else {
                    items.append(Item(id: "f\(start)", content: .fold(id: start, count: i - start), rowIDs: []))
                }
            }
        } else {
            items = raw
        }
        for item in items {
            for row in item.rowIDs where rowToItem[row] == nil { rowToItem[row] = item.id }
        }
    }

    func itemID(forRow row: Int) -> String? { rowToItem[row] }

    @MainActor
    func isCurrent(_ item: Item, document: DiffDocument) -> Bool {
        guard let index = document.currentHunk, document.result.hunks.indices.contains(index) else { return false }
        let range = document.result.hunks[index].rowRange
        return item.rowIDs.contains { range.contains($0) }
    }

    /// Unchanged/modified rows pair with themselves; runs of removed and added
    /// rows are zipped so they sit side by side.
    static func zip(_ rows: [DiffRow]) -> [(DiffRow?, DiffRow?)] {
        var out: [(DiffRow?, DiffRow?)] = []
        var i = 0
        while i < rows.count {
            if rows[i].kind == .unchanged || rows[i].kind == .modified {
                out.append((rows[i], rows[i]))
                i += 1
                continue
            }
            var lefts: [DiffRow] = [], rights: [DiffRow] = []
            while i < rows.count, rows[i].kind == .removed || rows[i].kind == .added {
                if rows[i].kind == .removed { lefts.append(rows[i]) } else { rights.append(rows[i]) }
                i += 1
            }
            for k in 0..<max(lefts.count, rights.count) {
                out.append((k < lefts.count ? lefts[k] : nil, k < rights.count ? rights[k] : nil))
            }
        }
        return out
    }
}

// MARK: - Row views

private let codeFont = Font.system(size: 12.5, design: .monospaced)

private func attributed(_ segments: [DiffSegment], emphasis: Color?) -> AttributedString {
    var out = AttributedString()
    for seg in segments {
        var piece = AttributedString(seg.text.isEmpty ? "" : seg.text)
        if seg.isChanged, let emphasis { piece.backgroundColor = emphasis }
        out += piece
    }
    if out.characters.isEmpty { out = AttributedString(" ") }
    return out
}

private struct LineNumber: View {
    let number: Int?
    let width: CGFloat
    var body: some View {
        Text(number.map(String.init) ?? "")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: width, alignment: .trailing)
            .padding(.trailing, 8)
    }
}

private struct MoveBadge: View {
    @ObservedObject var document: DiffDocument
    let row: DiffRow
    let side: DiffDocument.Side

    var body: some View {
        if let move = document.result.move(id: row.moveID),
           (side == .left ? row.left?.number == move.from.lowerBound : row.right?.number == move.to.lowerBound) {
            let target = side == .left ? move.to : move.from
            Button {
                document.focus(move: move, side: side == .left ? .right : .left)
            } label: {
                Label(side == .left ? "moved to \(target.lowerBound)" : "moved from \(target.lowerBound)", systemImage: "arrow.left.arrow.right")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(DiffPalette.moved.opacity(0.18)))
                    .foregroundStyle(DiffPalette.moved)
            }
            .buttonStyle(.plain)
            .help(move.similarity < 1 ? "Moved and edited (\(Int(move.similarity * 100))% similar)" : "Moved block — click to jump to its other location")
        }
    }
}

private struct SplitRowView: View {
    @ObservedObject var document: DiffDocument
    let left: DiffRow?
    let right: DiffRow?
    let gutter: CGFloat
    let dark: Bool
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            cell(left, side: .left)
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
            cell(right, side: .right)
        }
        .overlay(alignment: .leading) {
            if isCurrent { Rectangle().fill(Color.accentColor).frame(width: 3) }
        }
    }

    @ViewBuilder
    private func cell(_ row: DiffRow?, side: DiffDocument.Side) -> some View {
        let line = side == .left ? row?.left : row?.right
        let moved = row?.moveID != nil
        let showEmphasis = row?.kind == .modified || moved
        HStack(alignment: .top, spacing: 0) {
            LineNumber(number: line?.number, width: gutter)
            if let line {
                Text(attributed(line.segments, emphasis: showEmphasis ? DiffPalette.emphasis(side: side, moved: moved, dark: dark) : nil))
                    .font(codeFont)
                    .lineLimit(document.wrapLines ? nil : 1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let row, moved { MoveBadge(document: document, row: row, side: side).padding(.horizontal, 6) }
            } else {
                Color.clear.frame(maxWidth: .infinity, minHeight: 16)
            }
        }
        .padding(.vertical, 1.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(row, line: line, side: side))
    }

    private func background(_ row: DiffRow?, line: DiffLine?, side: DiffDocument.Side) -> Color {
        guard let row else { return Color.secondary.opacity(dark ? 0.06 : 0.04) }   // filler opposite an add/remove
        guard line != nil else { return Color.secondary.opacity(dark ? 0.06 : 0.04) }
        return DiffPalette.rowTint(row.kind, side: side, moved: row.moveID != nil, dark: dark)
    }
}

private struct UnifiedRowView: View {
    @ObservedObject var document: DiffDocument
    let line: UnifiedHunk.Line
    let gutter: CGFloat
    let dark: Bool
    let isCurrent: Bool

    var body: some View {
        let side: DiffDocument.Side = line.kind == .added ? .right : .left
        let moved = line.moveID != nil
        let row = document.result.rows.indices.contains(line.rowID) ? document.result.rows[line.rowID] : nil
        let emphasis = (row?.kind == .modified || moved) && line.kind != .context
        HStack(alignment: .top, spacing: 0) {
            LineNumber(number: line.leftNumber, width: gutter)
            LineNumber(number: line.rightNumber, width: gutter)
            Text(line.kind == .removed ? "−" : (line.kind == .added ? "+" : " "))
                .font(codeFont)
                .foregroundStyle(line.kind == .removed ? DiffPalette.removed : (line.kind == .added ? DiffPalette.added : .secondary))
                .frame(width: 14)
            Text(attributed(line.segments, emphasis: emphasis ? DiffPalette.emphasis(side: side, moved: moved, dark: dark) : nil))
                .font(codeFont)
                .lineLimit(document.wrapLines ? nil : 1)
                .fixedSize(horizontal: !document.wrapLines, vertical: false)
                .textSelection(.enabled)
                .frame(maxWidth: document.wrapLines ? .infinity : nil, alignment: .leading)
            if let row, moved {
                MoveBadge(document: document, row: row, side: side).padding(.horizontal, 6)
            }
            if !document.wrapLines { Spacer(minLength: 0) }
        }
        .padding(.vertical, 1.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(line.kind == .context ? Color.clear : DiffPalette.rowTint(.modified, side: side, moved: moved, dark: dark))
        .overlay(alignment: .leading) {
            if isCurrent { Rectangle().fill(Color.accentColor).frame(width: 3) }
        }
    }
}

private struct FoldRow: View {
    let count: Int
    let expand: () -> Void

    var body: some View {
        Button(action: expand) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.and.down")
                Text("\(count) unchanged line\(count == 1 ? "" : "s")")
                Spacer()
                Text("Show").foregroundStyle(Color.accentColor)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(Color.secondary.opacity(0.07))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct IdenticalView: View {
    @ObservedObject var document: DiffDocument

    var body: some View {
        let empty = document.leftText.isEmpty && document.rightText.isEmpty
        let ignored = document.result.rows.contains(where: \.hasIgnoredDifferences)
        VStack(spacing: 10) {
            Image(systemName: empty ? "doc.on.doc" : "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundStyle(empty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(DiffPalette.added))
            Text(empty ? "Nothing to compare yet" : "The two texts are identical")
                .font(.title3.weight(.semibold))
            Text(empty ? "Paste or open text in Edit mode." :
                    (ignored ? "Some differences are hidden by your ignore settings." : "There is no difference to show between these two texts."))
                .foregroundStyle(.secondary)
            if !empty {
                Text("\(document.result.stats.leftLineCount) lines")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
