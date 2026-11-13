import SwiftUI
import DiffactlyCore

/// Settings (⌘,): AI providers and the user's own rewrite prompts.
struct AISettingsView: View {
    var body: some View {
        TabView {
            ProvidersSettings()
                .tabItem { Label("AI Providers", systemImage: "cpu") }
            PromptsSettings()
                .tabItem { Label("Prompts", systemImage: "text.quote") }
        }
        .frame(width: 760, height: 520)
    }
}

// MARK: - Providers

private struct ProvidersSettings: View {
    @ObservedObject private var store = AIStore.shared
    @State private var selection: UUID?
    @State private var detectStatus: String?
    @State private var isDetecting = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.providers) { provider in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(provider.displayName)
                                Text(provider.model.isEmpty ? "No model chosen" : provider.model)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        } icon: {
                            Image(systemName: provider.kind.isLocal ? "desktopcomputer" : "cloud")
                        }
                        .tag(provider.id)
                    }
                }
                .overlay {
                    if store.providers.isEmpty {
                        Text("No providers yet").foregroundStyle(.tertiary)
                    }
                }
                Divider()
                HStack(spacing: 4) {
                    Menu {
                        Section("Cloud") {
                            ForEach(LLMProviderKind.allCases.filter { !$0.isLocal && $0 != .custom }) { kind in
                                Button(kind.title) { selection = store.addProvider(kind).id }
                            }
                        }
                        Section("Local") {
                            ForEach(LLMProviderKind.allCases.filter(\.isLocal)) { kind in
                                Button(kind.title) { selection = store.addProvider(kind).id }
                            }
                        }
                        Divider()
                        Button(LLMProviderKind.custom.title) { selection = store.addProvider(.custom).id }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add a provider")
                    Button {
                        if let selection { store.removeProvider(id: selection) }
                        selection = store.providers.first?.id
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selection == nil)
                    .help("Remove the selected provider and its API key")
                    Spacer()
                    Button {
                        detect()
                    } label: {
                        if isDetecting { ProgressView().controlSize(.mini) } else { Text("Detect Local") }
                    }
                    .buttonStyle(.borderless)
                    .help("Look for LM Studio, oMLX, Ollama and llama.cpp on their default ports")
                }
                .padding(6)
            }
            .frame(width: 230)
            Divider()
            Group {
                if let id = selection, let provider = store.provider(id: id) {
                    ProviderDetail(provider: provider).id(id)
                } else {
                    VStack(spacing: 8) {
                        Text("Add a cloud API or a local server with +, or press Detect Local.")
                            .foregroundStyle(.secondary)
                        if let detectStatus { Text(detectStatus).font(.callout).foregroundStyle(.secondary) }
                    }
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { if selection == nil { selection = store.providers.first?.id } }
    }

    private func detect() {
        isDetecting = true
        Task {
            let found = await store.detectLocalServers()
            isDetecting = false
            detectStatus = found.isEmpty ? "No local server answered on the default ports." : "Found \(found.formatted(.list(type: .and)))."
            if selection == nil { selection = store.providers.first?.id }
        }
    }
}

private struct ProviderDetail: View {
    @ObservedObject private var store = AIStore.shared
    @State var provider: AIProvider
    @State private var apiKey = ""
    @State private var status: (ok: Bool, text: String)?
    @State private var isWorking = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $provider.name)
                LabeledContent("Type", value: provider.kind.title)
                TextField("Server URL", text: $provider.baseURL, prompt: Text(provider.kind.defaultBaseURL))
                if provider.baseURL != provider.kind.defaultBaseURL {
                    Button("Reset to \(provider.kind.defaultBaseURL)") { provider.baseURL = provider.kind.defaultBaseURL }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            Section {
                SecureField(provider.kind.requiresAPIKey ? "API key" : "API key (optional)", text: $apiKey)
                    .onChange(of: apiKey) { _, key in store.setAPIKey(key, for: provider.id) }
                Text("\(provider.kind.apiKeyHelp). Stored in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    TextField("Model", text: $provider.model, prompt: Text(provider.kind == .gemini ? "e.g. a gemini-… model" : "model name"))
                    if !provider.knownModels.isEmpty {
                        Menu {
                            ForEach(provider.knownModels, id: \.self) { m in Button(m) { provider.model = m } }
                        } label: { Image(systemName: "list.bullet") }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                    }
                }
                let efforts = ThinkingEffort.options(for: provider.kind)
                if !efforts.isEmpty {
                    Picker("Thinking", selection: $provider.thinking) {
                        ForEach(efforts) { Text($0.title).tag($0) }
                    }
                    Text(thinkingHelp).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Fetch Models") { fetchModels() }
                    Button("Test Connection") { test() }
                    if isWorking { ProgressView().controlSize(.small) }
                    Spacer()
                }
                .disabled(isWorking)
                if let status {
                    Label(status.text, systemImage: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(status.ok ? DiffPalette.added : DiffPalette.removed)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            if provider.kind.isLocal {
                Section {
                    Text(localHint).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { apiKey = store.apiKey(for: provider.id) }
        .onChange(of: provider) { _, new in store.update(new) }
    }

    private var thinkingHelp: String {
        switch provider.kind {
        case .oMLX:
            return "Sets the model’s reasoning effort (Qwen 3.8 defaults to its highest) and caps its thinking: Low about 2k tokens, Medium about 8k. Lower is much faster; Off skips thinking, which usually rewrites less thoroughly."
        case .openAI:
            return "Reasoning effort for o-series and GPT-5 models. Other models reject it, so keep Full for them."
        case .gemini:
            return "Thinking budget for Gemini 2.5 and later: Low about 2k tokens, Medium about 8k. Some Pro models can’t turn thinking off."
        case .openRouter:
            return "Reasoning effort for models that think; others ignore it."
        default:
            return "Off switches thinking off for Qwen-style models (vLLM, llama.cpp); Low and Medium set the effort for gpt-oss and Ollama. Servers ignore what they don’t support."
        }
    }

    private var localHint: String {
        switch provider.kind {
        case .lmStudio: return "In LM Studio open the Developer tab, load a model and start the server (default port 1234)."
        case .oMLX: return "Run `omlx serve` (default port 8000). oMLX serves MLX models on Apple silicon through an OpenAI-compatible API."
        case .ollama: return "Run `ollama serve` and pull a model, e.g. `ollama pull llama3.2`. Ollama’s OpenAI-compatible API is on port 11434."
        case .llamaCpp: return "Run `llama-server -m model.gguf` (default port 8080)."
        default: return ""
        }
    }

    private var endpoint: LLMEndpoint {
        LLMEndpoint(kind: provider.kind, baseURL: provider.baseURL, apiKey: apiKey, model: provider.model, thinking: provider.thinking)
    }

    private func fetchModels() {
        isWorking = true
        status = nil
        let endpoint = endpoint
        Task {
            defer { isWorking = false }
            do {
                let models = try await LLMClient(endpoint: endpoint).listModelInfo()
                provider.setModels(models)
                let context = provider.contextLength.map { " \(provider.model) reads up to \($0.formatted()) tokens." } ?? ""
                status = (true, "\(models.count) model\(models.count == 1 ? "" : "s") available.\(context)")
            } catch {
                status = (false, error.localizedDescription)
            }
        }
    }

    private func test() {
        isWorking = true
        status = nil
        let endpoint = endpoint
        Task {
            defer { isWorking = false }
            do {
                let started = Date()
                var reply = "", thought = 0
                for try await delta in LLMClient(endpoint: endpoint).stream(LLMRequest(
                    system: "", messages: [LLMMessage(.user, "Reply with the single word: ready")], maxTokens: 1_024)) {
                    switch delta {
                    case .text(let t): reply += t
                    case .reasoning(let t): thought += t.count
                    case .truncated: break
                    }
                }
                let text = RewritePrompt.clean(reply)
                let seconds = Date().timeIntervalSince(started).formatted(.number.precision(.fractionLength(1)))
                if text.isEmpty {
                    // A reasoning model can spend the whole small budget thinking; it still answered.
                    status = (true, "Connected in \(seconds) s. \(provider.model) is a reasoning model and was still thinking at the test’s token limit.")
                } else {
                    status = (true, "Connected in \(seconds) s. \(provider.model) replied “\(text.prefix(60))”\(thought > 0 ? " after thinking" : "").")
                }
            } catch {
                status = (false, error.localizedDescription)
            }
        }
    }
}

// MARK: - Prompts

private struct PromptsSettings: View {
    @ObservedObject private var store = AIStore.shared
    @State private var selection: String? = RewritePreset.humanizeID

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    Section("Built-in") {
                        ForEach(RewritePreset.builtIns) { Text($0.name).tag($0.id) }
                    }
                    Section("My Prompts") {
                        ForEach(store.customPrompts) { Text($0.name).tag($0.id) }
                        if store.customPrompts.isEmpty {
                            Text("None yet").foregroundStyle(.tertiary)
                        }
                    }
                }
                Divider()
                HStack(spacing: 4) {
                    Button { selection = store.addPrompt().id } label: { Image(systemName: "plus") }
                        .help("New prompt")
                    Button {
                        if let selection { store.removePrompt(id: selection) }
                        selection = store.customPrompts.last?.id ?? RewritePreset.humanizeID
                    } label: { Image(systemName: "minus") }
                        .disabled(selection.flatMap(store.prompt(id:))?.isBuiltIn != false)
                        .help("Delete the selected prompt")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 230)
            Divider()
            if let id = selection, let prompt = store.prompt(id: id) {
                PromptDetail(prompt: prompt) { selection = store.addPrompt(basedOn: prompt).id }
                    .id(id)
            } else {
                Text("Select a prompt").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct PromptDetail: View {
    @ObservedObject private var store = AIStore.shared
    @State var prompt: RewritePreset
    let duplicate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Name", text: $prompt.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.headline)
                    .disabled(prompt.isBuiltIn)
                Button("Duplicate", action: duplicate)
            }
            Text("Instructions").font(.subheadline.weight(.semibold))
            TextEditor(text: $prompt.instructions)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                .disabled(prompt.isBuiltIn)
            Group {
                if prompt.isBuiltIn {
                    Text("Built-in prompts can’t be edited. Duplicate this one to make your own version.")
                } else {
                    Text("""
                    Describe the rewrite you want. Diffactly adds the source and blend settings, the strength, the fact-keeping rules, the AI-tell checklist (if on) and the output rules for you.
                    For full control, use placeholders and the prompt becomes the message itself: \(RewritePrompt.placeholders.joined(separator: " ")). {{text}} is whatever the Source setting picks.
                    """)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .onChange(of: prompt) { _, new in store.updatePrompt(new) }
    }
}
