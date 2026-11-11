import SwiftUI
import AppKit
import DiffactlyCore

/// The AI sheet: rewrite (humanize, paraphrase or merge) the texts, or
/// summarize the main differences between them, with a cloud or local model.
struct RewriteSheet: View {
    @ObservedObject var document: DiffDocument
    @ObservedObject var session: RewriteSession
    @ObservedObject private var store = AIStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showPrompt = false
    @State private var isFetchingModels = false
    @State private var modelError: String?
    @State private var detectStatus: String?

    var body: some View {
        VStack(spacing: 0) {
            if store.providers.isEmpty {
                noProviders
            } else {
                Picker("Task", selection: $session.task) {
                    ForEach(AITask.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.vertical, 10)
                .disabled(session.phase.isRunning)
                Divider()
                HSplitView {
                    controls
                        .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
                    resultPane
                        .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 740, idealWidth: 940, maxWidth: 1400, minHeight: 420, idealHeight: 640, maxHeight: 1000)
        .onAppear { session.prepare(for: document) }
    }

    // MARK: Empty state

    private var noProviders: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Connect an AI model").font(.title2.weight(.semibold))
            Text("Rewrite and difference summaries work with cloud APIs (OpenAI, Anthropic, Google AI Studio, OpenRouter) and local servers (LM Studio, oMLX, Ollama, llama.cpp).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            HStack {
                Button("Detect Local Servers") { detect() }
                SettingsLink { Text("Open AI Settings…") }
                    .buttonStyle(.borderedProminent)
            }
            if let detectStatus { Text(detectStatus).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detect() {
        detectStatus = "Looking for local servers…"
        Task {
            let found = await store.detectLocalServers()
            detectStatus = found.isEmpty
                ? "No local server answered on the default ports. Start LM Studio’s server, `omlx serve`, `ollama serve` or `llama-server`, or add one in Settings."
                : "Found \(found.formatted(.list(type: .and)))."
        }
    }

    // MARK: Controls

    private var controls: some View {
        Form {
            switch session.task {
            case .rewrite: rewriteControls
            case .summary: summaryControls
            }
            Section {
                TextField("Extra instructions", text: $session.extraNotes, prompt: Text(session.task == .rewrite ? "e.g. British spelling, keep under 200 words" : "e.g. focus on legal or pricing changes"), axis: .vertical)
                    .lineLimit(2...4)
                Button("Show Full Prompt…") { showPrompt = true }
                    .buttonStyle(.link)
                    .popover(isPresented: $showPrompt, arrowEdge: .trailing) {
                        PromptPreview(messages: session.previewMessages(document: document, store: store))
                    }
            }
            ReferenceDocumentsSection(library: session.references, document: document, openFileNames: session.openFileNames(document))
            Section("Model") { modelControls }
        }
        .formStyle(.grouped)
        .disabled(session.phase.isRunning)
    }

    @ViewBuilder
    private var rewriteControls: some View {
        Section("Source") {
            Picker("Rewrite from", selection: $session.target) {
                Text(document.title(for: .left)).tag(RewriteTarget.left)
                Text("Both").tag(RewriteTarget.both)
                Text(document.title(for: .right)).tag(RewriteTarget.right)
                if session.passage != nil {
                    Text("Selection").tag(RewriteTarget.selection)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help(session.passage == nil ? "Select a passage in an editor (or right-click a paragraph) to rewrite just that part" : "Rewrite a whole text, merge both, or just the selected passage")
            switch session.target {
            case .both: blendControl
            case .selection: selectionInfo
            default: EmptyView()
            }
        }

        Section("Style") {
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
            Picker("Strength", selection: $session.strength) {
                ForEach(RewriteStrength.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Avoid AI tells", isOn: $session.avoidAITells)
                .help("Adds a humanizer checklist: no “delve”, “testament”, “not just X but Y”, em-dash chains, summary endings, …")
            Picker("Second pass", selection: $session.secondPass) {
                ForEach(SecondPassMode.allCases) { Text($0.title).tag($0) }
            }
            .help("Sends the draft back to the model to restore lost facts and rework sentences that still sound machine-written. “If tells remain” only does this when the scan still flags something, and names the flagged phrases.")
            Toggle("Keep formatting", isOn: $session.preserveFormatting)
        }
    }

    @ViewBuilder
    private var summaryControls: some View {
        Section("Summary") {
            Picker("Detail", selection: $session.summaryDetail) {
                ForEach(SummaryDetail.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Report", selection: $session.summaryFocus) {
                ForEach(SummaryFocus.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Text("The model sees “\(document.title(for: .right))” as the newer version of “\(document.title(for: .left))”, along with the line diff Diffactly computed (with your ignore options), so it reports real changes. Changed facts and numbers come first.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !DiffSummaryPrompt.includesFullTexts(session.summarySpec(document: document)) {
                Label("These texts are long, so only the diff is sent.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var selectionInfo: some View {
        if let passage = session.passage {
            let counts = TextCounts(passage.text)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(counts.words.formatted()) word\(counts.words == 1 ? "" : "s") selected in \(document.title(for: passage.side))")
                    .font(.callout.weight(.medium))
                Text(passage.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.callout)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .truncationMode(.middle)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor.opacity(0.6)).frame(width: 2) }
                Text("The model reads the whole \(document.title(for: passage.side).lowercased()) text\(session.references.hasEnabledItems ? " and your reference documents" : "") so the new passage fits in, but rewrites only this part.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Also show the model “\(document.title(for: passage.side.other))”", isOn: $session.includeOtherSide)
                .disabled(document.text(for: passage.side.other).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Useful when the other side is an earlier or alternative version of the same text.")
        }
    }

    private var blendControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Slider(value: Binding(get: { 1 - session.leftWeight }, set: { session.leftWeight = 1 - $0 }), in: 0...1, step: 0.05) {
                Text("Blend")
            } minimumValueLabel: {
                Text(document.title(for: .left)).font(.caption)
            } maximumValueLabel: {
                Text(document.title(for: .right)).font(.caption)
            }
            .labelsHidden()
            HStack {
                ForEach([(1.0, "Like \(document.title(for: .left))"), (0.5, "Even mix"), (0.0, "Like \(document.title(for: .right))")], id: \.0) { weight, label in
                    Button(label) { session.leftWeight = weight }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(abs(session.leftWeight - weight) < 0.01 ? .accentColor : nil)
                }
            }
            Text(blendDescription).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var blendDescription: String {
        let l = Int((session.leftWeight * 100).rounded())
        let a = document.title(for: .left), b = document.title(for: .right)
        switch session.leftWeight {
        case 0.9...: return "Follows \(a) and only borrows missing details from \(b)."
        case 0.65..<0.9: return "Built on \(a) (\(l)%), with the best of \(b) folded in."
        case 0.35..<0.65: return "One merged text taking the clearer version of each point (\(l)/\(100 - l))."
        case 0.1..<0.35: return "Built on \(b) (\(100 - l)%), with the best of \(a) folded in."
        default: return "Follows \(b) and only borrows missing details from \(a)."
        }
    }

    @ViewBuilder
    private var modelControls: some View {
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
        }
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

    // MARK: Result

    private var resultPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(session.task == .summary ? "Differences" : session.outputPassage != nil ? "New Passage" : "Result")
                    .font(.headline)
                    .fixedSize()
                statusLabel
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if session.task == .rewrite { tellComparison.layoutPriority(1) }
                historyMenu
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            Divider()
            if session.wasTruncated, session.runTask == session.task {
                Label("The answer hit the output token limit and is cut off. Try a shorter text or a model with a larger limit.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(DiffPalette.modified)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            if let error = session.applyError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(DiffPalette.removed)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            switch session.task {
            case .rewrite: rewriteResult
            case .summary: summaryResult
            }
        }
    }

    private var rewriteResult: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $session.output)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .disabled(session.phase.isRunning)
                    .onChange(of: session.output) { _, _ in
                        if !session.phase.isRunning { session.refreshTells() }
                    }
                if session.output.isEmpty {
                    placeholderText
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            if let tells = session.outputTells, !tells.hits.isEmpty, !session.phase.isRunning {
                Divider()
                TellList(report: tells)
            }
        }
    }

    private var summaryResult: some View {
        ZStack(alignment: .topLeading) {
            ScrollView {
                MarkdownText(markdown: session.summary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            if session.summary.isEmpty {
                placeholderText
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private var placeholderText: some View {
        Group {
            if session.isThinking, session.runTask == session.task {
                Text("The model is thinking before it answers…")
            } else if session.phase.isRunning, session.runTask == session.task {
                Text("Waiting for the model…")
            } else if let blocker = session.blocker(document: document, store: store) {
                Text(blocker)
            } else if session.task == .rewrite, session.target == .selection {
                Text("Press Rewrite (⌘↩) to rewrite the selected passage. The new version streams in here; edit it if you like, then replace the selection, or put an edited copy on the other side to compare.")
            } else if session.task == .rewrite {
                Text("Press Rewrite (⌘↩) to generate. The result streams in here; edit it if you like, then put it into either side to see the changes.")
            } else {
                Text("Press Summarize (⌘↩) for a list of the main differences between “\(document.title(for: .left))” and “\(document.title(for: .right))”: what was added, removed or changed, and which version suits what.")
            }
        }
        .foregroundStyle(.tertiary)
        .padding(14)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var statusLabel: some View {
        if session.runTask == session.task || session.phase.isRunning {
            switch session.phase {
            case .drafting, .auditing, .summarizing:
                ProgressView().controlSize(.small)
                Text(runningText).foregroundStyle(.secondary).monospacedDigit()
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .help(message)
                    .textSelection(.enabled)
            case .finished:
                if let duration = session.duration {
                    Text(finishedText(duration)).foregroundStyle(.secondary).monospacedDigit()
                        .help(finishedText(duration))
                }
            case .idle:
                EmptyView()
            }
        }
    }

    private var runningText: String {
        if session.isThinking {
            let chars = session.reasoningCharacters
            return chars > 0 ? "Thinking… (\(chars.formatted(.number.notation(.compactName))) chars)" : "Thinking…"
        }
        switch session.phase {
        case .auditing: return "Second pass…"
        case .summarizing: return "Comparing…"
        default: return "Writing…"
        }
    }

    private func finishedText(_ duration: TimeInterval) -> String {
        let time = duration < 60 ? "\(Int(duration.rounded())) s" : "\(Int(duration) / 60) min \(Int(duration) % 60) s"
        guard session.runTask == .rewrite else { return "Done in \(time)" }
        let words = TextCounts(session.output).words
        return "\(words.formatted()) words · \(time)\(session.didAudit ? " · 2 passes" : "")"
    }

    /// "AI tells: Original 9 · Changed 4 · Result 1" (or "Selection 3 · Result 0"),
    /// shortened to just the coloured counts when the pane is narrow.
    private var tellComparison: some View {
        var chips: [(String, AITells.Report)] = []
        if session.target == .selection, let passage = session.passage {
            chips.append(("Selection", AITells.scan(passage.text)))
        } else {
            chips.append((document.title(for: .left), document.leftTells))
            chips.append((document.title(for: .right), document.rightTells))
        }
        if let out = session.outputTells { chips.append(("Result", out)) }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Text("AI tells").foregroundStyle(.secondary)
                ForEach(chips, id: \.0) { tellChip($0.0, $0.1, showTitle: true) }
            }
            HStack(spacing: 6) {
                ForEach(chips, id: \.0) { tellChip($0.0, $0.1, showTitle: false) }
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .help("AI tells: overused AI words, stock phrases and formulaic sentence shapes in each text (\(chips.map { "\($0.0) \($0.1.hits.count)" }.joined(separator: ", "))). A heuristic, not a detector.")
    }

    private func tellChip(_ title: String, _ report: AITells.Report, showTitle: Bool) -> some View {
        HStack(spacing: 3) {
            Circle().fill(report.level.color).frame(width: 6, height: 6)
            Text(showTitle ? "\(title) \(report.hits.count)" : "\(report.hits.count)").monospacedDigit()
        }
        .lineLimit(1)
        .fixedSize()
        .help("\(title): \(report.level.title) (\(report.hits.count) in \(report.wordCount) words, \(report.emDashes) em dashes)")
    }

    private var historyMenu: some View {
        let items = session.history.filter { $0.task == session.task }
        return Menu {
            if items.isEmpty { Text("No earlier results") }
            ForEach(items) { item in
                Button("\(item.date.formatted(date: .omitted, time: .shortened)) · \(item.label)") { session.restore(item) }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(items.isEmpty || session.phase.isRunning)
        .help("Bring back an earlier result from this window")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Close") { session.stop(); dismiss() }
                .keyboardShortcut(.cancelAction)
            if session.task == .rewrite, session.applied != nil {
                Button("Revert Last Use") { session.revert(in: document) }
                    .help("Put back the text that the result replaced")
            }
            Spacer()
            if !store.providers.isEmpty { actions }
        }
        .padding(12)
    }

    @ViewBuilder
    private var actions: some View {
        tokenEstimate
        Button {
            copy(currentResult)
        } label: { Label("Copy", systemImage: "doc.on.doc") }
            .disabled(currentResult.isEmpty || session.phase.isRunning)
            .help(session.task == .summary ? "Copy the summary as Markdown" : "Copy the result")
        if session.task == .rewrite {
            if session.outputPassage != nil { usePassageMenu } else { useResultMenu }
        }
        if session.phase.isRunning {
            Button("Stop") { session.stop() }
                .keyboardShortcut(.defaultAction)
        } else {
            Button(runTitle) { session.run(document: document, store: store) }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(session.blocker(document: document, store: store) != nil)
        }
    }

    /// "≈ 12k tokens in", in orange when it won't fit the model's context window.
    private var tokenEstimate: some View {
        let tokens = session.estimatedInputTokens(document: document, store: store)
        let window = session.resolvedProvider(in: store)?.contextLength
        let tooBig = window.map { Double(tokens) > Double($0) * 0.85 } ?? false
        let text = "≈ \(tokens.formatted(.number.notation(.compactName))) tokens in" + (window.map { " / \($0.formatted(.number.notation(.compactName)))" } ?? "")
        return Label {
            Text(text).monospacedDigit()
        } icon: {
            if tooBig { Image(systemName: "exclamationmark.triangle.fill") }
        }
        .font(.caption)
        .foregroundStyle(tooBig ? AnyShapeStyle(DiffPalette.modified) : AnyShapeStyle(.tertiary))
        .help(tooBig
              ? "This request is close to or over the model’s context window, so the model may fail or forget the start. Turn off some reference documents, or use a model with a bigger window."
              : "Rough size of the request\(window.map { ", out of the model’s \($0.formatted())-token context window" } ?? ""). Local models need a window at least this big plus room for the answer.")
    }

    private var currentResult: String { session.task == .rewrite ? session.output : session.summary }

    private var runTitle: String {
        switch session.task {
        case .rewrite: return session.output.isEmpty ? "Rewrite" : "Rewrite Again"
        case .summary: return session.summary.isEmpty ? "Summarize" : "Summarize Again"
        }
    }

    private var useResultMenu: some View {
        Menu {
            Button("Replace \(document.title(for: .right)) and Compare") { use(.right, compare: true) }
            Button("Replace \(document.title(for: .left)) and Compare") { use(.left, compare: true) }
            Divider()
            Button("Replace \(document.title(for: .right))") { use(.right, compare: false) }
            Button("Replace \(document.title(for: .left))") { use(.left, compare: false) }
        } label: {
            Text("Use Result")
        } primaryAction: {
            use(.right, compare: true)
        }
        .fixedSize()
        .disabled(session.output.isEmpty || session.phase.isRunning)
        .help("Put the result into the \(document.title(for: .right).lowercased()) side and show the differences")
    }

    private var usePassageMenu: some View {
        let side = session.outputPassage?.side ?? .right
        return Menu {
            Button("Replace Selection in \(document.title(for: side))") { usePassage(inPlace: true) }
            Button("Put Edited Copy in \(document.title(for: side.other)) and Compare") { usePassage(inPlace: false) }
        } label: {
            Text("Replace Selection")
        } primaryAction: {
            usePassage(inPlace: true)
        }
        .fixedSize()
        .disabled(session.output.isEmpty || session.phase.isRunning)
        .help("Swap the selected passage for the new one (⌘Z in the editor undoes it), or keep \(document.title(for: side).lowercased()) as is and compare against an edited copy")
    }

    private func usePassage(inPlace: Bool) {
        if session.applyPassage(in: document, inPlace: inPlace) { dismiss() }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func use(_ side: DiffDocument.Side, compare: Bool) {
        session.apply(to: side, in: document, compare: compare)
        if compare { dismiss() }
    }
}

extension AITells.Level {
    var color: Color {
        switch self {
        case .low: return DiffPalette.added
        case .some: return DiffPalette.modified
        case .high: return DiffPalette.removed
        }
    }
}

// MARK: - Pieces

/// The tells left in the result, as chips.
private struct TellList: View {
    let report: AITells.Report

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("Still flagged:").foregroundStyle(.secondary)
                ForEach(report.topPhrases.prefix(14), id: \.phrase) { item in
                    Text(item.count > 1 ? "\(item.phrase) ×\(item.count)" : item.phrase)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(DiffPalette.modified.opacity(0.15), in: Capsule())
                }
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

/// Read-only view of exactly what gets sent to the model.
private struct PromptPreview: View {
    let messages: RewritePrompt.Messages

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("System").font(.headline)
                Text(messages.system).textSelection(.enabled)
                Divider()
                Text("User").font(.headline)
                Text(messages.user).textSelection(.enabled)
            }
            .font(.system(.caption, design: .monospaced))
            .padding(14)
        }
        .frame(width: 520, height: 520)
    }
}

/// Renders the small Markdown subset models use for summaries: headings,
/// bullet and numbered lists, paragraphs, and inline bold / italic / code.
struct MarkdownText: View {
    let markdown: String

    private enum Block: Hashable {
        case heading(String, level: Int)
        case bullet(String, indent: Int)
        case numbered(String, marker: String)
        case paragraph(String)
        case rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let text, let level):
            Text(inline(text))
                .font(level <= 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, 6)
        case .bullet(let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(text)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .numbered(let text, let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary).monospacedDigit()
                Text(inline(text)).fixedSize(horizontal: false, vertical: true)
            }
        case .paragraph(let text):
            Text(inline(text)).fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider()
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph.removeAll()
        }
        for rawLine in markdown.components(separatedBy: "\n") {
            let indent = rawLine.prefix { $0 == " " || $0 == "\t" }.count / 2
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                flush()
                let level = line.prefix { $0 == "#" }.count
                result.append(.heading(line.dropFirst(level).trimmingCharacters(in: .whitespaces), level: level))
            } else if line == "---" || line == "***" {
                flush()
                result.append(.rule)
            } else if let marker = ["- ", "* ", "• "].first(where: line.hasPrefix) {
                flush()
                result.append(.bullet(String(line.dropFirst(marker.count)), indent: indent))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
                      line[line.index(after: dot)...].hasPrefix(" ") {
                flush()
                result.append(.numbered(String(line[line.index(dot, offsetBy: 2)...]), marker: String(line[...dot])))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return result
    }
}
