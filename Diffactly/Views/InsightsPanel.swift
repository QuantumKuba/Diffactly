import SwiftUI
import Charts
import DiffactlyCore

/// Optional side panel with graphs derived from the comparison.
struct InsightsPanel: View {
    @ObservedObject var document: DiffDocument

    var body: some View {
        let result = document.result
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SimilarityCard(stats: result.stats, identical: result.isIdentical)
                StatTiles(stats: result.stats)
                Card(title: "AI writing tells", subtitle: "Stock words, phrases and sentence shapes models overuse") {
                    AITellsSummary(document: document)
                }
                if result.isIdentical {
                    Text("Charts appear once the texts differ.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                } else {
                    Card(title: "Composition", subtitle: "Every line, by what happened to it") {
                        CompositionChart(slices: DiffInsights.composition(result))
                    }
                    Card(title: "Change map", subtitle: "Where the changes are · click to jump") {
                        ChangeMapChart(buckets: DiffInsights.changeMap(result, buckets: 28)) { row in
                            document.focus(row: row)
                        }
                    }
                    Card(title: "Word shifts", subtitle: "Words used more (+) or less (−) often") {
                        WordShiftChart(shifts: document.wordShifts)
                    }
                    if !result.moves.isEmpty {
                        Card(title: "Moved blocks", subtitle: nil) {
                            MoveList(document: document)
                        }
                    }
                }
            }
            .padding(14)
        }
        .background(.background)
    }
}

// MARK: - Building blocks

private struct Card<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.secondary.opacity(0.07)))
    }
}

private struct SimilarityCard: View {
    let stats: DiffStats
    let identical: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Similarity").font(.headline)
                Spacer()
                Text(stats.similarity, format: .percent.precision(.fractionLength(identical ? 0 : 1)))
                    .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(DiffPalette.added.gradient)
                        .frame(width: max(6, geo.size.width * stats.similarity))
                }
            }
            .frame(height: 8)
            Text("\(stats.leftLineCount) → \(stats.rightLineCount) lines")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if stats.lineEndingsDiffer || stats.trailingNewlineDiffers {
                Label(stats.lineEndingsDiffer ? "Line endings differ (CRLF vs LF)" : "Newline at end of file differs", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.secondary.opacity(0.07)))
    }
}

private struct StatTiles: View {
    let stats: DiffStats

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                tile("Added", stats.addedLines, DiffPalette.added, detail: "+\(stats.addedWords) words · +\(stats.addedCharacters) chars")
                tile("Removed", stats.removedLines, DiffPalette.removed, detail: "−\(stats.removedWords) words · −\(stats.removedCharacters) chars")
            }
            GridRow {
                tile("Modified", stats.modifiedLines, DiffPalette.modified, detail: "edited in place")
                tile("Moved", stats.movedLines, DiffPalette.moved, detail: "lines")
            }
        }
    }

    private func tile(_ title: String, _ value: Int, _ color: Color, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(value)").font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
            Text(detail).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.secondary.opacity(0.07)))
    }
}

private struct CompositionChart: View {
    let slices: [DiffInsights.Slice]

    var body: some View {
        let visible = slices.filter { $0.lines > 0 }
        Chart(visible) { slice in
            BarMark(x: .value("Lines", slice.lines), y: .value("Comparison", "lines"))
                .foregroundStyle(by: .value("Kind", slice.category.title))
        }
        .chartForegroundStyleScale(domain: DiffInsights.Category.allCases.map(\.title),
                                   range: DiffInsights.Category.allCases.map(DiffPalette.color(for:)))
        .chartYAxis(.hidden)
        .chartXAxis(.hidden)
        .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
        .frame(height: 64)
    }
}

private struct ChangeMapChart: View {
    let buckets: [DiffInsights.Bucket]
    let jump: (Int) -> Void

    private struct Point: Identifiable {
        let bucket: Int
        let kind: DiffInsights.Category
        let lines: Int
        var id: String { "\(bucket)-\(kind.rawValue)" }
    }

    var body: some View {
        let points = buckets.flatMap { b in
            [Point(bucket: b.id, kind: .removed, lines: b.removed),
             Point(bucket: b.id, kind: .added, lines: b.added),
             Point(bucket: b.id, kind: .modified, lines: b.modified),
             Point(bucket: b.id, kind: .moved, lines: b.moved)].filter { $0.lines > 0 }
        }
        let domain = buckets.map { String($0.id) }
        VStack(spacing: 2) {
        Chart(points) { p in
            BarMark(x: .value("Position", String(p.bucket)), y: .value("Lines", p.lines), width: .ratio(0.75))
                .foregroundStyle(by: .value("Kind", p.kind.title))
                .cornerRadius(1.5)
        }
        .chartForegroundStyleScale(domain: DiffInsights.Category.allCases.map(\.title),
                                   range: DiffInsights.Category.allCases.map(DiffPalette.color(for:)))
        .chartXScale(domain: domain)
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let plot = proxy.plotFrame else { return }
                        let x = location.x - geo[plot].origin.x
                        guard let value: String = proxy.value(atX: x), let index = Int(value), buckets.indices.contains(index) else { return }
                        let target = buckets[index...].first { $0.firstChangedRow != nil }?.firstChangedRow
                            ?? buckets[..<index].last { $0.firstChangedRow != nil }?.firstChangedRow
                        if let target { jump(target) }
                    }
            }
        }
        .frame(height: 100)
        HStack {
            Text("Start")
            Spacer()
            Text("End")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        }
    }
}

private struct WordShiftChart: View {
    let shifts: [DiffInsights.WordShift]

    var body: some View {
        if shifts.isEmpty {
            Text("No word frequency changes.").font(.callout).foregroundStyle(.secondary)
        } else {
            let peak = Double(max(1, shifts.map { abs($0.delta) }.max() ?? 1))
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                ForEach(shifts) { shift in
                    GridRow {
                        Text(shift.word)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: 84, alignment: .trailing)
                        DivergingBar(value: Double(shift.delta) / peak)
                            .frame(height: 12)
                        Text(shift.delta > 0 ? "+\(shift.delta)" : "−\(abs(shift.delta))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(shift.delta > 0 ? DiffPalette.added : DiffPalette.removed)
                            .frame(width: 30, alignment: .leading)
                    }
                    .help("“\(shift.word)”: \(shift.leftCount) → \(shift.rightCount)")
                }
            }
        }
    }
}

/// A bar growing left (negative) or right (positive) from a centre line.
private struct DivergingBar: View {
    let value: Double   // -1…1

    var body: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            let width = max(2, half * abs(value))
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 1).offset(x: half)
                RoundedRectangle(cornerRadius: 2)
                    .fill(value >= 0 ? DiffPalette.added : DiffPalette.removed)
                    .frame(width: width)
                    .offset(x: value >= 0 ? half : half - width)
            }
        }
    }
}

private struct MoveList: View {
    @ObservedObject var document: DiffDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(document.result.moves) { move in
                Button {
                    document.focus(move: move, side: .left)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left.arrow.right").foregroundStyle(DiffPalette.moved)
                        Text("Lines \(span(move.from)) → \(span(move.to))").font(.callout.monospacedDigit())
                        Spacer()
                        Text(move.similarity < 1 ? "edited" : "exact")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func span(_ r: ClosedRange<Int>) -> String { r.count == 1 ? "\(r.lowerBound)" : "\(r.lowerBound)–\(r.upperBound)" }
}

// MARK: - AI tells

/// Per-side count of AI-writing tells with the most frequent ones, plus
/// shortcuts into the AI sheet.
private struct AITellsSummary: View {
    @ObservedObject var document: DiffDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(.left, document.leftTells)
            row(.right, document.rightTells)
            HStack {
                Button("Humanize…") { document.showAI(.rewrite) }
                Button("Summarize Differences…") { document.showAI(.summary) }
            }
            .controlSize(.small)
            Text("A heuristic, not an AI detector: people use these words too.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func row(_ side: DiffDocument.Side, _ report: AITells.Report) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(report.level.color).frame(width: 7, height: 7)
                Text(document.title(for: side)).font(.callout.weight(.medium))
                Spacer()
                Text(report.wordCount == 0 ? "empty" : "\(report.hits.count) · \(report.level.title.lowercased())")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !report.hits.isEmpty {
                Text(report.topPhrases.prefix(6).map { $0.count > 1 ? "\($0.phrase) ×\($0.count)" : $0.phrase }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .help("\(report.hits.count) tells in \(report.wordCount) words, \(report.emDashes) em dashes")
    }
}
