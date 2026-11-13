import Foundation
import Security
import DiffactlyCore

// MARK: - Providers

/// One configured AI service: a cloud API or a local server.
struct AIProvider: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: LLMProviderKind
    var baseURL: String
    var model: String
    /// Models last fetched from the server, offered in pickers.
    var knownModels: [String] = []
    /// Context windows the server reported, by model (optional so settings
    /// saved before this existed still decode).
    var contextLengths: [String: Int]?
    /// How much a reasoning model may think (nil in settings saved before this existed).
    var thinkingEffort: ThinkingEffort?

    init(kind: LLMProviderKind, name: String? = nil) {
        self.kind = kind
        self.name = name ?? kind.title
        self.baseURL = kind.defaultBaseURL
        self.model = kind.defaultModel
    }

    var displayName: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? kind.title : name }

    var thinking: ThinkingEffort {
        get { thinkingEffort ?? .full }
        set { thinkingEffort = newValue }
    }

    /// The chosen model's context window, when known.
    var contextLength: Int? { contextLengths?[model] }

    mutating func setModels(_ models: [LLMModelInfo]) {
        knownModels = models.map(\.id)
        let lengths = Dictionary(models.compactMap { m in m.contextLength.map { (m.id, $0) } }, uniquingKeysWith: { a, _ in a })
        contextLengths = lengths.isEmpty ? nil : lengths
        if model.isEmpty { model = knownModels.first ?? "" }
    }
}

// MARK: - Prompts

/// A rewrite style: a built-in preset or one the user wrote.
struct RewritePreset: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var instructions: String
    var isBuiltIn: Bool = false

    static let humanizeID = "builtin.humanize"

    static let builtIns: [RewritePreset] = [
        RewritePreset(id: humanizeID, name: "Humanize", instructions: """
            Rewrite the text so it reads as naturally human-written. Remove the signs of AI writing (stock vocabulary, formulaic sentence shapes, filler and chatbot residue) while keeping the meaning, the facts and the writer's voice.
            """, isBuiltIn: true),
        RewritePreset(id: "builtin.paraphrase", name: "Paraphrase", instructions: """
            Paraphrase the text: express the same content in clearly different wording and sentence structure, so the result is not a near-copy of the source, while every point and nuance stays exactly the same.
            """, isBuiltIn: true),
        RewritePreset(id: "builtin.polish", name: "Polish", instructions: """
            Correct grammar, spelling, punctuation and awkward phrasing, and smooth the flow between sentences. Do not change the content, the structure or the tone.
            """, isBuiltIn: true),
        RewritePreset(id: "builtin.concise", name: "Make Concise", instructions: """
            Make the text noticeably shorter and tighter, roughly a third shorter. Remove padding, repetition and throat-clearing. Keep every substantive point.
            """, isBuiltIn: true),
        RewritePreset(id: "builtin.simplify", name: "Plain Language", instructions: """
            Rewrite in plain language that a general reader understands on first read: short common words, one idea per sentence, jargon explained or replaced. Keep it accurate and don't talk down to the reader.
            """, isBuiltIn: true),
        RewritePreset(id: "builtin.formal", name: "Formal", instructions: """
            Rewrite in a formal, professional register suitable for academic or business writing: precise and measured, with no slang or contractions, and without stiff filler or jargon for its own sake.
            """, isBuiltIn: true),
        RewritePreset(id: "builtin.casual", name: "Conversational", instructions: """
            Rewrite in a relaxed, conversational register, as a knowledgeable person would explain it to a colleague. Use contractions and everyday words. Keep it accurate.
            """, isBuiltIn: true),
    ]
}

// MARK: - Store

/// App-wide AI settings: providers (API keys in the Keychain) and the user's prompts.
@MainActor
final class AIStore: ObservableObject {
    static let shared = AIStore()

    @Published var providers: [AIProvider] { didSet { save(providers, Keys.providers) } }
    @Published var customPrompts: [RewritePreset] { didSet { save(customPrompts, Keys.prompts) } }
    /// Bumped when a key changes so views showing "key saved" refresh.
    @Published private(set) var keyRevision = 0

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let providers = "ai.providers"
        static let prompts = "ai.customPrompts"
    }

    init() {
        providers = Self.load([AIProvider].self, Keys.providers) ?? []
        customPrompts = Self.load([RewritePreset].self, Keys.prompts) ?? []
    }

    var allPrompts: [RewritePreset] { RewritePreset.builtIns + customPrompts }

    func prompt(id: String) -> RewritePreset? { allPrompts.first { $0.id == id } }

    func provider(id: UUID?) -> AIProvider? { providers.first { $0.id == id } }

    func update(_ provider: AIProvider) {
        guard let i = providers.firstIndex(where: { $0.id == provider.id }), providers[i] != provider else { return }
        providers[i] = provider
    }

    @discardableResult
    func addProvider(_ kind: LLMProviderKind) -> AIProvider {
        var provider = AIProvider(kind: kind)
        let sameKind = providers.filter { $0.kind == kind }.count
        if sameKind > 0 { provider.name = "\(kind.title) \(sameKind + 1)" }
        providers.append(provider)
        return provider
    }

    func removeProvider(id: UUID) {
        providers.removeAll { $0.id == id }
        Keychain.delete(account: id.uuidString)
        keyRevision += 1
    }

    func endpoint(for provider: AIProvider) -> LLMEndpoint {
        LLMEndpoint(kind: provider.kind, baseURL: provider.baseURL, apiKey: apiKey(for: provider.id), model: provider.model, thinking: provider.thinking)
    }

    // MARK: API keys

    func apiKey(for id: UUID) -> String { Keychain.read(account: id.uuidString) ?? "" }

    func setAPIKey(_ key: String, for id: UUID) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { Keychain.delete(account: id.uuidString) } else { Keychain.save(trimmed, account: id.uuidString) }
        keyRevision += 1
    }

    // MARK: Prompts

    @discardableResult
    func addPrompt(basedOn base: RewritePreset? = nil) -> RewritePreset {
        let prompt = RewritePreset(
            id: "custom.\(UUID().uuidString)",
            name: base.map { "\($0.name) (Copy)" } ?? "New Prompt",
            instructions: base?.instructions ?? "Rewrite the text so that …"
        )
        customPrompts.append(prompt)
        return prompt
    }

    func updatePrompt(_ prompt: RewritePreset) {
        guard !prompt.isBuiltIn, let i = customPrompts.firstIndex(where: { $0.id == prompt.id }), customPrompts[i] != prompt else { return }
        customPrompts[i] = prompt
    }

    func removePrompt(id: String) { customPrompts.removeAll { $0.id == id } }

    // MARK: Local servers

    /// Probes the default ports of LM Studio, oMLX, Ollama and llama.cpp and
    /// adds every server that answers (and isn't configured yet). Returns the
    /// names of the servers found.
    func detectLocalServers() async -> [String] {
        let kinds = LLMProviderKind.allCases.filter(\.isLocal)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        let session = URLSession(configuration: config)
        let results = await withTaskGroup(of: (LLMProviderKind, [LLMModelInfo]?).self) { group in
            for kind in kinds {
                group.addTask {
                    let client = LLMClient(endpoint: LLMEndpoint(kind: kind, baseURL: kind.defaultBaseURL, model: ""), session: session)
                    return (kind, try? await client.listModelInfo())
                }
            }
            var found: [(LLMProviderKind, [LLMModelInfo])] = []
            for await (kind, models) in group { if let models { found.append((kind, models)) } }
            return found
        }
        var names: [String] = []
        for (kind, models) in results.sorted(by: { $0.0.title < $1.0.title }) {
            names.append(kind.title)
            if let i = providers.firstIndex(where: { $0.kind == kind && $0.baseURL == kind.defaultBaseURL }) {
                providers[i].setModels(models)
            } else {
                var provider = AIProvider(kind: kind)
                provider.setModels(models)
                providers.append(provider)
            }
        }
        return names
    }

    // MARK: Persistence

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Keychain

/// API keys live in the login Keychain, never in UserDefaults.
enum Keychain {
    private static let service = "com.diffactly.ai-provider"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ value: String, account: String) {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(account)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Diffactly AI provider key"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func read(account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
