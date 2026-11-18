import SwiftUI
import AppKit
import DiffactlyCore

/// Looks up a suggestion by id for the editor's card popover (it may be gone
/// by the time SwiftUI redraws).
struct SuggestionCardHost: View {
    @ObservedObject var document: DiffDocument
    let session: RewriteSession
    let id: UUID

    var body: some View {
        if document.acceptedRewrite(id: id) != nil {
            RewriteHistoryCard(document: document, id: id)
        } else if let suggestion = document.suggestion(id: id) {
            if suggestion.status == .configuring {
                SuggestionSetupView(suggestion: suggestion, document: document, session: session)
            } else {
                SuggestionCard(suggestion: suggestion, document: document, session: session)
            }
        } else {
            Text("This suggestion is gone.")
                .foregroundStyle(.secondary)
                .padding(16)
        }
    }
}

/// The card shown on a passage with a pending AI suggestion: the proposed
/// text with its changes marked, and Accept / Reject / Regenerate / settings /
/// side-by-side comparison. Nothing changes in the text until Accept.
struct SuggestionCard: View {
    @ObservedObject var suggestion: AISuggestion
    @ObservedObject var document: DiffDocument
    @ObservedObject var session: RewriteSession
    @State private var showsSettings = false
    @State private var showsChanges = true
    @State private var counterpart: PassageMatch.Match?
    /// The selection in the combined text, for rewriting part of it.
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var selectionRequest: TextSelectionRequest?
    /// The rewritten part under the pointer (its row or its text).
    @State private var focusedPart: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            if showsSettings {
                Divider()
                settings
            }
            SettingsChangedBanner(suggestion: suggestion, session: session, isDefault: showsSettings) {
                session.regenerate(suggestion, document: document, store: .shared)
                showsSettings = false
            }
            Divider()
            buttons
        }
        .padding(14)
        .frame(width: 460)
        .onAppear {
            counterpart = RewriteSession.counterpart(side: suggestion.side, range: suggestion.range, in: document)
            takeProposedRefinement()
        }
        .onChange(of: suggestion.proposedRefinement) { _, _ in takeProposedRefinement() }
        .onChange(of: suggestion.shownVersionID) { _, _ in
            selection = NSRange(location: 0, length: 0)
            focusedPart = nil
        }
    }

    /// Selects the words picked in the editor, ready to rewrite on their own.
    private func takeProposedRefinement() {
        guard let proposed = suggestion.proposedRefinement else { return }
        suggestion.proposedRefinement = nil
        guard let range = suggestion.composedRange(forVersion: proposed) else { return }
        showsChanges = false
        selection = range
        selectionRequest = TextSelectionRequest(range: range)
    }

    private func refineSelection() {
        guard let range = suggestion.versionRange(forComposed: selection) else { return }
        session.refine(suggestion, range: range, document: document, store: .shared)
        selection = NSRange(location: 0, length: 0)
        document.suggestionStatusChanged()
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(DiffPalette.suggestion)
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.label.isEmpty ? "AI suggestion" : suggestion.label)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let basis = suggestion.basisLabel {
                    Text(basis).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            SuggestionVersionPicker(suggestion: suggestion, document: document)
            status
        }
    }

    @ViewBuilder
    private var status: some View {
        switch suggestion.status {
        case .configuring:
            EmptyView()
        case .drafting, .auditing:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text(runningText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        case .ready:
            if let duration = suggestion.duration {
                Text(readyText(duration)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
        case .stale:
            Label("Out of date", systemImage: "clock.badge.exclamationmark").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var runningText: String {
        if suggestion.isThinking {
            let chars = suggestion.reasoningCharacters
            return chars > 0 ? "Thinking… (\(chars.formatted(.number.notation(.compactName))))" : "Thinking…"
        }
        return suggestion.status == .auditing ? "Second pass…" : "Writing…"
    }

    private func readyText(_ duration: TimeInterval) -> String {
        let time = duration < 60 ? "\(Int(duration.rounded())) s" : "\(Int(duration) / 60) min \(Int(duration) % 60) s"
        return suggestion.didAudit ? "2 passes · \(time)" : time
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch suggestion.status {
        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .stale:
            Text("You edited this passage after asking, so the suggestion no longer fits. Regenerate to get one for the passage as it reads now.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        default:
            if suggestion.replacement.isEmpty {
                Text(suggestion.isThinking ? "The model is thinking before it answers…" : "Waiting for the model…")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if suggestion.isReady {
                        Picker("Show", selection: $showsChanges) {
                            Text("Changes").tag(true)
                            Text("New Text").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                    }
                    SuggestionTextView(display: SuggestionDisplay(suggestion, showsChanges: suggestion.isReady && showsChanges,
                                                                  focused: focusedPart),
                                       selection: $selection, request: selectionRequest,
                                       onPartClicked: { id in focusedPart = focusedPart == id ? nil : id })
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                    SuggestionPartsSection(suggestion: suggestion, document: document, session: session,
                                           selection: selection, focusedPart: $focusedPart, onRefine: refineSelection)
                }
            }
            if let truncation = suggestion.truncation {
                Label(truncationText(truncation), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(DiffPalette.modified)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if suggestion.isReady {
                let verification = AITells.verify(source: suggestion.original, result: suggestion.composedReplacement)
                if verification.sourceNumberCount > 0 {
                    HStack(spacing: 8) {
                        if verification.allNumbersPreserved {
                            Label("All \(verification.sourceNumberCount) number\(verification.sourceNumberCount == 1 ? "" : "s") kept", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(DiffPalette.added)
                        } else {
                            Label("Missing: \(verification.missingNumbers.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(DiffPalette.removed)
                        }
                    }
                    .font(.caption)
                    .monospacedDigit()
                }
                let tells = AITells.scan(suggestion.composedReplacement)
                if !tells.hits.isEmpty {
                    Text("Still flagged: " + tells.topPhrases.prefix(6).map(\.phrase).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func truncationText(_ truncation: RewriteTruncation) -> String {
        switch truncation {
        case .thinking: return "The model used its whole output budget thinking."
        case .secondPass: return "The second pass ran out of tokens while thinking, so this is the first draft."
        case .answer: return "The answer hit the output token limit and may be cut off."
        }
    }

    // MARK: Settings

    private var settings: some View {
        SuggestionSettingsForm(session: session, document: document, side: suggestion.side, counterpart: counterpart,
                                   onClearHighlights: {
                                       document.clearSourceMarks(on: suggestion.side.other)
                                       counterpart = RewriteSession.counterpart(side: suggestion.side, range: suggestion.range, in: document)
                                   })
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack(spacing: 8) {
            Button {
                session.regenerate(suggestion, document: document, store: .shared)
                showsSettings = false
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(showsSettings ? "Ask again with these settings" : "Ask again (uses the current AI settings)")
            Toggle(isOn: $showsSettings) { Label("Settings", systemImage: "slider.horizontal.3") }
                .toggleStyle(.button)
                .help("Prompt, strength, how much to draw on the other side, and model")
            Button {
                document.comparedSuggestion = suggestion
            } label: {
                Label("Compare", systemImage: "rectangle.split.2x1")
            }
            .disabled(!suggestion.isAcceptable)
            .help("See the whole \(document.title(for: suggestion.side).lowercased()) text with this suggestion side by side with the current one")
            Spacer()
            Button(suggestion.status.isRunning ? "Cancel" : "Reject") {
                if suggestion.status.isRunning, suggestion.canDiscardAttempt {
                    // Only this version: the earlier ones stay.
                    suggestion.discardAttempt()
                    document.suggestionStatusChanged()
                } else {
                    document.rejectSuggestion(suggestion.id)
                }
            }
            .help(suggestion.status.isRunning
                  ? (suggestion.canDiscardAttempt ? "Stop this version and go back to the earlier ones" : "Stop and discard this suggestion")
                  : "Discard this suggestion and keep the passage as it is")
            Button("Accept") {
                document.acceptSuggestion(suggestion.id)
            }
            // Return accepts, except while the settings (and their text field) are open.
            .keyboardShortcut(showsSettings ? nil : .defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!suggestion.isAcceptable)
            .help(suggestion.isReady && !suggestion.isAcceptable
                  ? "Wait for the rewritten parts to finish, or pick another of their versions"
                  : "Replace the passage with the suggestion, as shown (⌘Z in the editor undoes it)")
        }
    }
}

// MARK: - Side by side

/// The whole side with the suggestion applied next to the current text, as a
/// regular split comparison (with its connector ribbons).
struct SuggestionCompareSheet: View {
    @ObservedObject var document: DiffDocument
    @ObservedObject var suggestion: AISuggestion
    @StateObject private var preview: DiffDocument
    @Environment(\.dismiss) private var dismiss

    init(document: DiffDocument, suggestion: AISuggestion) {
        self.document = document
        self.suggestion = suggestion
        let title = document.title(for: suggestion.side)
        let preview = DiffDocument(
            left: document.text(for: suggestion.side),
            right: document.text(applying: suggestion) ?? document.text(for: suggestion.side),
            leftTitle: "\(title) now", rightTitle: "With suggestion",
            persistsSettings: false)
        preview.options = document.options
        preview.collapseUnchanged = true
        preview.wrapLines = true
        _preview = StateObject(wrappedValue: preview)
    }

    var body: some View {
        VStack(spacing: 0) {
            DiffOutputView(document: preview, layout: .split)
            Divider()
            HStack(spacing: 10) {
                Toggle("Collapse unchanged", isOn: $preview.collapseUnchanged)
                    .toggleStyle(.checkbox)
                SuggestionVersionPicker(suggestion: suggestion, document: document)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Reject") {
                    document.rejectSuggestion(suggestion.id)
                    dismiss()
                }
                Button("Accept") {
                    document.acceptSuggestion(suggestion.id)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!suggestion.isAcceptable)
            }
            .padding(12)
        }
        .frame(minWidth: 820, idealWidth: 1100, minHeight: 460, idealHeight: 680)
        // Show the versions picked here or in the card.
        .onChange(of: suggestion.composedReplacement) { _, _ in
            preview.rightText = document.text(applying: suggestion) ?? document.text(for: suggestion.side)
        }
    }
}
