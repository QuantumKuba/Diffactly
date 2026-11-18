import SwiftUI
import DiffactlyCore

/// The card on a passage an AI rewrite was accepted into: every text it has
/// had (the original first), a preview of any of them, and putting one back.
/// Switching is one undoable edit and keeps the whole history, so it's safe
/// to try each in place.
struct RewriteHistoryCard: View {
    @ObservedObject var document: DiffDocument
    let id: UUID
    /// The step being looked at (index into `texts`); nil for the text now.
    @State private var preview: Int?

    var body: some View {
        if let record = document.acceptedRewrite(id: id) {
            content(record)
                .padding(14)
                .frame(width: 460)
        } else {
            Text("This history is gone.")
                .foregroundStyle(.secondary)
                .padding(16)
        }
    }

    private func content(_ record: AcceptedRewrite) -> some View {
        let texts = record.texts
        let target = preview.flatMap { texts.indices.contains($0) ? $0 : nil }
        let showsOther = target.map { texts[$0] != record.text } ?? false
        return VStack(alignment: .leading, spacing: 10) {
            header(record)
            steps(record, target: target)
            VStack(alignment: .leading, spacing: 4) {
                Text(caption(record, showsOther: showsOther, target: target))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(changes(from: showsOther || record.state == .reverted ? record.text : record.original,
                                 to: showsOther ? texts[target!] : (record.state == .reverted ? record.latest : record.text)))
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            }
            if record.state == .edited {
                Label("You edited this passage after accepting. Switching puts in the text you pick, without those edits (⌘Z brings them back).",
                      systemImage: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            buttons(record, target: showsOther ? target : nil)
        }
    }

    // MARK: Parts

    private func header(_ record: AcceptedRewrite) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(DiffPalette.suggestion)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI rewrite history").font(.callout.weight(.semibold))
                Text(status(record)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
    }

    private func status(_ record: AcceptedRewrite) -> String {
        switch record.state {
        case .applied:
            let last = record.steps.last
            return "Accepted \(last.map { time($0.date) } ?? "")" + (last?.label.isEmpty == false ? " · \(last!.label)" : "")
        case .reverted: return "Showing the original"
        case .step(let i): return "Showing \(name(i, in: record))"
        case .edited: return "Edited since it was accepted"
        }
    }

    /// One row per text the passage has had; the one in the text is ticked,
    /// clicking one previews it below.
    private func steps(_ record: AcceptedRewrite, target: Int?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(record.texts.enumerated()), id: \.offset) { index, _ in
                let isCurrent = record.currentIndex == index && record.texts[index] == record.text
                let isPreviewed = target == index
                Button {
                    preview = isPreviewed ? nil : index
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isCurrent ? DiffPalette.suggestion : Color.secondary)
                        Text(name(index, in: record)).font(.callout.weight(isCurrent ? .semibold : .regular))
                        if index > 0 {
                            let step = record.steps[index - 1]
                            Text([time(step.date), step.label].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        if isCurrent { Text("In the text").font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(isPreviewed ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isCurrent ? "This is what the passage says now" : "Preview this text against the passage as it reads now")
            }
        }
    }

    private func buttons(_ record: AcceptedRewrite, target: Int?) -> some View {
        HStack(spacing: 8) {
            Button("Forget") { document.forgetRewrite(record.id) }
                .help("Stop keeping this passage’s history; the text stays as it is")
            if record.steps.last?.suggestion != nil, record.state == .applied {
                Button {
                    document.reopenRewrite(record.id)
                } label: {
                    Label("Reopen Versions", systemImage: "square.stack")
                }
                .help("Put back the text from before the last rewrite and open its suggestion again, with every version and rewritten part, to pick again")
            }
            Spacer()
            if let target {
                Button(target == 0 ? "Revert to Original" : "Use \(name(target, in: record))") {
                    document.showRewriteStep(target, of: record.id)
                    preview = nil
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .help("Put this text into the passage (⌘Z in the editor undoes it). The history keeps every step.")
            } else if record.state != .reverted {
                Button("Revert to Original") { document.revertRewrite(record.id) }
                    .help("Put back what the passage said before any AI rewrite (⌘Z in the editor undoes it)")
            } else if record.texts.count > 1 {
                Button("Use Rewrite Again") { document.showRewriteStep(record.texts.count - 1, of: record.id) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .help("Put the accepted rewrite back")
            }
        }
    }

    // MARK: Helpers

    private func caption(_ record: AcceptedRewrite, showsOther: Bool, target: Int?) -> String {
        if showsOther, let target { return "What switching to \(name(target, in: record)) would change" }
        // Back on the original: show what the rewrite would bring back.
        if record.state == .reverted { return "What using the rewrite again would change" }
        return "What the AI changed"
    }

    private func name(_ index: Int, in record: AcceptedRewrite) -> String {
        index == 0 ? "Original" : (record.steps.count == 1 ? "Rewrite" : "Rewrite \(index)")
    }

    private func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    /// `to` with what it drops from `from` struck out and what it adds tinted.
    private func changes(from: String, to: String) -> AttributedString {
        var out = AttributedString()
        let pieces = DiffEngine.inlineChanges(from.trimmingCharacters(in: .whitespacesAndNewlines),
                                              to.trimmingCharacters(in: .whitespacesAndNewlines))
        for change in pieces {
            var piece = AttributedString(change.text)
            switch change.kind {
            case .equal: break
            case .removed:
                piece.foregroundColor = DiffPalette.removed
                piece.strikethroughStyle = .single
                piece.backgroundColor = DiffPalette.removed.opacity(0.12)
            case .added:
                piece.backgroundColor = DiffPalette.added.opacity(0.22)
            }
            out += piece
        }
        return out
    }
}
