import SwiftUI
import DiffactlyCore

/// The card for a passage waiting to be humanized: its settings, open, and a
/// button that starts it. Nothing is sent to the model before that; Cancel
/// (or Esc) drops the passage's highlight again.
struct SuggestionSetupView: View {
    @ObservedObject var suggestion: AISuggestion
    @ObservedObject var document: DiffDocument
    @ObservedObject var session: RewriteSession
    @ObservedObject private var store = AIStore.shared
    @AppStorage(RewriteSession.optionsFirstKey) private var optionsFirst = false
    @State private var counterpart: PassageMatch.Match?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            SuggestionSettingsForm(session: session, document: document, side: suggestion.side, counterpart: counterpart,
                                   onClearHighlights: {
                                       document.clearSourceMarks(on: suggestion.side.other)
                                       counterpart = RewriteSession.counterpart(side: suggestion.side, range: suggestion.range, in: document)
                                   })
            if isEdited {
                Label("You edited the passage since selecting it; \(promptName) uses it as it reads now.", systemImage: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let blocker {
                HStack(spacing: 6) {
                    Label(blocker, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(DiffPalette.modified)
                    SettingsLink { Text("Open Settings…") }
                        .buttonStyle(.link)
                }
                .font(.caption)
            }
            Divider()
            buttons
        }
        .padding(14)
        .frame(width: 460)
        .onAppear { counterpart = RewriteSession.counterpart(side: suggestion.side, range: suggestion.range, in: document) }
    }

    private var promptName: String { session.resolvedPrompt(in: store).name }
    private var blocker: String? { session.suggestionBlocker(in: store) }

    /// The passage no longer reads as it did when it was selected.
    private var isEdited: Bool {
        let ns = document.text(for: suggestion.side) as NSString
        return NSMaxRange(suggestion.range) > ns.length || ns.substring(with: suggestion.range) != suggestion.original
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(DiffPalette.suggestion)
            VStack(alignment: .leading, spacing: 2) {
                Text("Suggestion Settings")
                    .font(.callout.weight(.semibold))
                Text("\(wordCount) from “\(document.title(for: suggestion.side))”. Nothing is sent until you start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
        }
    }

    private var wordCount: String {
        let words = suggestion.original.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        return "\(words.formatted()) word\(words == 1 ? "" : "s")"
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Toggle("Always show these first", isOn: $optionsFirst)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("Open these settings every time you use \(promptName) Selection (⌥⌘E) instead of starting at once. ⌥⇧⌘E always shows them.")
            Spacer(minLength: 8)
            Button("Cancel") {
                document.rejectSuggestion(suggestion.id)
            }
            .keyboardShortcut(.cancelAction)
            .help("Discard and keep the passage as it is")
            Button {
                session.startSuggestion(suggestion, document: document, store: store)
            } label: {
                Label(promptName, systemImage: "sparkles")
                    .lineLimit(1)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(blocker != nil)
            .help(blocker ?? "Send the passage to \(session.resolvedProvider(in: store)?.model ?? "the model") with these settings (Return)")
        }
    }
}

/// The settings an inline suggestion is written with. They are the AI
/// session's own, so a change here also shows in the AI sheet.
struct SuggestionSettingsForm: View {
    @ObservedObject var session: RewriteSession
    @ObservedObject var document: DiffDocument
    /// The editor the passage is in.
    let side: DiffDocument.Side
    /// The other side's matching part of the passage (nil when there is none).
    let counterpart: PassageMatch.Match?
    /// Clears the highlights on the other side (see `PassageBasisControl`).
    var onClearHighlights: (() -> Void)? = nil

    var body: some View {
        Form {
            PromptPicker(session: session)
            Picker("Strength", selection: $session.strength) {
                ForEach(RewriteStrength.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(session.strength.transparentSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !document.text(for: side.other).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                PassageBasisControl(session: session, title: document.title(for: side),
                                    otherTitle: document.title(for: side.other), counterpart: counterpart,
                                    onClearHighlights: onClearHighlights)
            }
            Toggle("Avoid AI tells", isOn: $session.avoidAITells)
            AcademicVoiceToggle(session: session, showsCaption: false)
            Picker("Second pass", selection: $session.secondPass) {
                ForEach(SecondPassMode.allCases) { Text($0.title).tag($0) }
            }
            TextField("Extra instructions", text: $session.extraNotes, prompt: Text("e.g. British spelling"), axis: .vertical)
                .lineLimit(1...3)
            ModelControls(session: session)
            if session.references.hasEnabledItems {
                Text("Also reads your reference documents and the other open tabs (manage them in the AI panel, ⌥⌘R).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.columns)
        .controlSize(.small)
    }
}

/// Shown on a finished suggestion once the settings no longer match the ones
/// it was written with, so regenerating is the obvious next step.
struct SettingsChangedBanner: View {
    @ObservedObject var suggestion: AISuggestion
    @ObservedObject var session: RewriteSession
    @ObservedObject private var store = AIStore.shared
    /// Return regenerates (while the card's settings are open).
    var isDefault: Bool
    let regenerate: () -> Void

    var body: some View {
        if isFinished, session.settingsChanged(since: suggestion, store: store) {
            HStack(spacing: 8) {
                Label("The settings changed since this was written.", systemImage: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(action: regenerate) {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(isDefault ? .defaultAction : nil)
                .help("Ask again with the new settings")
            }
        }
    }

    private var isFinished: Bool {
        switch suggestion.status {
        case .ready, .failed: return true
        default: return false
        }
    }
}
