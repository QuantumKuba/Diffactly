import SwiftUI

/// "‹ V2 of 3 ›": steps through the versions of an AI answer, with a menu
/// listing them all. Used by inline suggestions and the AI sheet.
struct VersionSwitcher<Entries: View>: View {
    /// The number on show (1 for V1); nil when what's on show isn't one of them.
    let current: Int?
    let count: Int
    /// The newest version is being written while an earlier one is on show.
    var isWriting = false
    var isDisabled = false
    /// The title when nothing numbered is on show ("Keep V2 wording", say).
    var noneTitle: String?
    let select: (Int) -> Void
    @ViewBuilder let entries: () -> Entries

    var body: some View {
        HStack(spacing: 2) {
            if count > 1 {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(isDisabled || current == 1)
                    .help("Previous version")
                    .accessibilityLabel("Previous Version")
            }
            Menu {
                entries()
            } label: {
                Text(title).monospacedDigit()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isDisabled)
            .help("Each time the AI answers again it adds a version. Pick the one to show and use.")
            if count > 1 {
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(isDisabled || current == count)
                    .help("Next version")
                    .accessibilityLabel("Next Version")
            }
            if isWriting {
                ProgressView().controlSize(.mini)
                    .help("V\(count) is being written")
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .fixedSize()
    }

    private var title: String {
        if let current { return "V\(current) of \(count)" }
        if let noneTitle { return noneTitle }
        return count == 0 ? "Results" : "\(count) Version\(count == 1 ? "" : "s")"
    }

    /// From nothing on show, back goes to the newest and forward to V1.
    private func step(_ delta: Int) {
        let number = (current ?? (delta < 0 ? count + 1 : 0)) + delta
        if (1...max(count, 1)).contains(number) { select(number) }
    }
}

enum VersionTitle {
    /// " · 2 parts rewritten", for a version with rewritten parts.
    static func parts(_ count: Int) -> String {
        count == 0 ? "" : " · \(count) part\(count == 1 ? "" : "s") rewritten"
    }

    /// "V2 · 10:42 · Humanize · Moderate · gpt-5", for a version menu.
    static func entry(number: Int, date: Date, label: String) -> String {
        "V\(number) · \(date.formatted(date: .omitted, time: .shortened))" + (label.isEmpty ? "" : " · \(label)")
    }
}

/// The versions of an inline suggestion: each Regenerate adds one, and the
/// one on show is what the card, Compare and Accept use. Hidden until there's
/// more than one, and once the passage has been edited (out of date).
struct SuggestionVersionPicker: View {
    @ObservedObject var suggestion: AISuggestion
    let document: DiffDocument

    var body: some View {
        if suggestion.versionCount > 1, suggestion.status != .stale {
            VersionSwitcher(current: suggestion.shownVersionNumber, count: suggestion.versionCount,
                            isWriting: suggestion.attemptStatus?.isRunning == true && suggestion.shownVersionID != nil,
                            select: { number in show { suggestion.showVersion(number: number) } }) {
                ForEach(Array(suggestion.versions.enumerated()), id: \.element.id) { index, version in
                    Toggle(VersionTitle.entry(number: index + 1, date: version.date, label: version.label)
                           + VersionTitle.parts(suggestion.refinementCount(forVersion: version.id)),
                           isOn: Binding(get: { suggestion.shownVersionID == version.id },
                                         set: { if $0 { show { suggestion.showVersion(version.id) } } }))
                }
                if let status = suggestion.attemptStatus {
                    Toggle("V\(suggestion.versions.count + 1) · \(status.isRunning ? "Writing…" : "Failed")",
                           isOn: Binding(get: { suggestion.shownVersionID == nil },
                                         set: { if $0 { show { suggestion.showVersion(nil) } } }))
                }
            }
        }
    }

    /// Switches, then repaints the passage's tint (a version being written is
    /// painted as pending).
    private func show(_ change: () -> Void) {
        change()
        document.suggestionStatusChanged()
    }
}
