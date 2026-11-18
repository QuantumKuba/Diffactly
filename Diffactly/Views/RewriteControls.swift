import SwiftUI
import DiffactlyCore

// Controls shared by the AI sheet and the inline suggestion card. Both edit
// the same `RewriteSession` settings, so a change in one shows in the other.

/// The rewrite prompt, with a shortcut to editing prompts in Settings.
struct PromptPicker: View {
    @ObservedObject var session: RewriteSession
    @ObservedObject private var store = AIStore.shared

    var body: some View {
        HStack {
            Picker("Prompt", selection: $session.promptID) {
                Section("Built-in") {
                    ForEach(RewritePreset.builtIns) { Text($0.name).tag($0.id) }
                }
                if !store.customPrompts.isEmpty {
                    Section("My Prompts") {
                        ForEach(store.customPrompts) { Text($0.name).tag($0.id) }
                    }
                }
            }
            SettingsLink { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help("Write your own rewriting and paraphrasing prompts in Settings → Prompts")
        }
    }
}

/// Layers the academic humanizer rules onto the chosen prompt. Always on (and
/// locked) for the Academic Humanize prompt, which is nothing without them.
struct AcademicVoiceToggle: View {
    @ObservedObject var session: RewriteSession
    /// Explains the combination with the chosen prompt under the toggle.
    var showsCaption = true

    var body: some View {
        Toggle("Academic humanizer", isOn: Binding(get: { session.appliesAcademic }, set: { session.academicVoice = $0 }))
            .disabled(session.promptIsAcademic)
            .help("For papers, theses, rebuttals and funding proposals. Keeps the scholarly register, calibrated hedging, terms, equations and every citation; fixes over-claiming, hype and padding; matches each claim to the evidence in the text. Works with any prompt.")
        if showsCaption, session.appliesAcademic, let caption {
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var caption: String? {
        switch session.promptID {
        case RewritePreset.academicID:
            return nil
        default:
            return "Applies the prompt in an academic voice: hedges, terms, equations and citations are kept, and claims are matched to their evidence."
        }
    }
}

/// How a passage rewrite uses the matching part of the other side: from
/// "background only" through an even merge to "follow the other version".
/// Text the user highlighted on the other side replaces the automatic match.
struct PassageBasisControl: View {
    @ObservedObject var session: RewriteSession
    /// Title of the side the passage is in, and of the other side.
    let title: String
    let otherTitle: String
    /// The other side's matching (or highlighted) part of the passage; nil when there is none.
    let counterpart: PassageMatch.Match?
    /// Removes the highlights on the other side (nil hides the button).
    var onClearHighlights: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let counterpart, counterpart.isMarked {
                HStack(alignment: .firstTextBaseline) {
                    Label("Using your highlights in “\(otherTitle)”", systemImage: "highlighter")
                        .foregroundStyle(DiffPalette.sourceMark)
                    Spacer(minLength: 8)
                    if let onClearHighlights {
                        Button("Clear", action: onClearHighlights)
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .help("Remove the highlights in “\(otherTitle)” and go back to the automatic match")
                    }
                }
                if counterpart.isIdentical {
                    Text("The highlighted text reads the same as the passage, so there’s nothing to blend.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    blend(counterpart, disclosure: "Highlighted text in “\(otherTitle)”")
                }
                Toggle("Also show the rest of “\(otherTitle)” as background", isOn: $session.includeOtherSide)
                    .help("Send the whole other version too, for context. The highlighted text is used either way.")
            } else {
                Toggle("Use “\(otherTitle)” as well", isOn: $session.includeOtherSide)
                    .help("Show the model the other side too: as background, or to blend with its version of this passage.")
                if session.includeOtherSide {
                    if let counterpart, !counterpart.isIdentical {
                        blend(counterpart, disclosure: "Matching passage in “\(otherTitle)”")
                    } else {
                        Text(counterpart == nil
                             ? "“\(otherTitle)” has no matching passage, so it’s read as background only."
                             : "This passage reads the same in “\(otherTitle)”, so there’s nothing to blend; it’s read as background.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("To choose exactly what to take from “\(otherTitle)”, select it there and choose Use as AI Source (⌥⌘U).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func blend(_ counterpart: PassageMatch.Match, disclosure: String) -> some View {
        Slider(value: Binding(get: { 1 - session.passageWeight }, set: { session.passageWeight = 1 - $0 }), in: 0...1, step: 0.05) {
            Text("Based on")
        } minimumValueLabel: {
            Text("Selection").font(.caption)
        } maximumValueLabel: {
            Text(otherTitle).font(.caption)
        }
        .labelsHidden()
        HStack {
            ForEach([(1.0, "Selection"), (0.5, "Even mix"), (0.0, otherTitle)], id: \.0) { weight, label in
                Button(label) { session.passageWeight = weight }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .lineLimit(1)
                    .tint(abs(session.passageWeight - weight) < 0.01 ? .accentColor : nil)
            }
        }
        Text(description(marked: counterpart.isMarked)).font(.caption).foregroundStyle(.secondary)
        DisclosureGroup(disclosure) {
            Text(counterpart.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(8)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
    }

    private func description(marked: Bool) -> String {
        let w = session.passageWeight
        let percent = Int((w * 100).rounded())
        let other = marked ? "your highlights in “\(otherTitle)”" : "“\(otherTitle)”"
        let otherVersion = marked ? "the highlighted text" : "“\(otherTitle)”’s version"
        switch w {
        case 0.9...: return "Rewrites the selection. \(other.prefix(1).uppercased() + other.dropFirst()) \(marked ? "are" : "is") only checked for facts and missing details."
        case 0.65..<0.9: return "Built on the selection (\(percent)%), with the best of \(other) folded in."
        case 0.35..<0.65: return "Merges the selection and \(otherVersion) (\(percent)/\(100 - percent))."
        case 0.1..<0.35: return "Built on \(otherVersion) (\(100 - percent)%), with the best of the selection folded in."
        default: return "Follows \(otherVersion), fitted into \(title)."
        }
    }
}

/// Provider, model and thinking effort.
struct ModelControls: View {
    @ObservedObject var session: RewriteSession
    @ObservedObject private var store = AIStore.shared
    @State private var isFetchingModels = false
    @State private var modelError: String?

    var body: some View {
        let provider = session.resolvedProvider(in: store)
        Picker("Provider", selection: Binding(get: { provider?.id }, set: { session.providerID = $0 })) {
            ForEach(store.providers) { p in
                Label(p.displayName, systemImage: p.kind.isLocal ? "desktopcomputer" : "cloud").tag(Optional(p.id))
            }
        }
        if let provider {
            HStack {
                TextField("Model", text: Binding(
                    get: { provider.model },
                    set: { var p = provider; p.model = $0; store.update(p) }
                ), prompt: Text("model name"))
                Menu {
                    if provider.knownModels.isEmpty { Text("No models fetched yet") }
                    ForEach(provider.knownModels, id: \.self) { model in
                        Button(model) { var p = provider; p.model = model; store.update(p) }
                    }
                    Divider()
                    Button("Fetch Models") { fetchModels(provider) }
                } label: {
                    if isFetchingModels { ProgressView().controlSize(.small) } else { Image(systemName: "list.bullet") }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Pick from the models this server offers")
            }
            if let modelError { Text(modelError).font(.caption).foregroundStyle(.red) }
            let efforts = ThinkingEffort.options(for: provider.kind)
            if !efforts.isEmpty {
                Picker("Thinking", selection: Binding(
                    get: { provider.thinking },
                    set: { var p = provider; p.thinking = $0; store.update(p) }
                )) {
                    ForEach(efforts) { Text($0.title).tag($0) }
                }
                .help("How long a reasoning model may think before answering. Lower is much faster; Off skips thinking, which usually rewrites less thoroughly. Saved with the provider.")
            }
        }
    }

    private func fetchModels(_ provider: AIProvider) {
        isFetchingModels = true
        modelError = nil
        Task {
            defer { isFetchingModels = false }
            do {
                let models = try await LLMClient(endpoint: store.endpoint(for: provider)).listModelInfo()
                var p = store.provider(id: provider.id) ?? provider
                p.setModels(models)
                store.update(p)
                if models.isEmpty { modelError = "The server listed no models." }
            } catch {
                modelError = error.localizedDescription
            }
        }
    }
}

/// Custom temperature toggle and slider.
struct TemperatureControls: View {
    @ObservedObject var session: RewriteSession

    var body: some View {
        Toggle("Custom temperature", isOn: $session.useCustomTemperature)
            .help("Off leaves sampling to the model’s default. 0.7–1.0 suits rewriting; higher drifts from the meaning. Summaries are capped at 0.7.")
        if session.useCustomTemperature {
            HStack {
                Slider(value: $session.temperature, in: 0...1.5, step: 0.05)
                Text(session.temperature, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }
}
