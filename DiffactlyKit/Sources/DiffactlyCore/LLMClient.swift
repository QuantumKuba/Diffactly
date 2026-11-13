import Foundation

/// The wire protocol a provider speaks. Most local servers and OpenRouter use
/// the OpenAI chat-completions shape; Anthropic and Google have their own.
public enum LLMAPIStyle: String, Codable, Sendable {
    case openAI, anthropic, gemini
}

/// The services Diffactly knows how to talk to, with their defaults.
public enum LLMProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case openAI, anthropic, gemini, openRouter
    case lmStudio, oMLX, ollama, llamaCpp
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google AI Studio (Gemini)"
        case .openRouter: return "OpenRouter"
        case .lmStudio: return "LM Studio"
        case .oMLX: return "oMLX"
        case .ollama: return "Ollama"
        case .llamaCpp: return "llama.cpp server"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }

    public var apiStyle: LLMAPIStyle {
        switch self {
        case .anthropic: return .anthropic
        case .gemini: return .gemini
        default: return .openAI
        }
    }

    public var isLocal: Bool {
        switch self {
        case .lmStudio, .oMLX, .ollama, .llamaCpp: return true
        default: return false
        }
    }

    /// Cloud services need a key; local servers usually don't.
    public var requiresAPIKey: Bool {
        switch self {
        case .openAI, .anthropic, .gemini, .openRouter: return true
        default: return false
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .lmStudio: return "http://localhost:1234/v1"
        case .oMLX: return "http://localhost:8000/v1"
        case .ollama: return "http://localhost:11434/v1"
        case .llamaCpp: return "http://localhost:8080/v1"
        case .custom: return "http://localhost:8000/v1"
        }
    }

    /// A sensible starting model; empty means "pick one from Fetch Models".
    public var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-5-5"
        default: return ""
        }
    }

    public var apiKeyHelp: String {
        switch self {
        case .openAI: return "platform.openai.com → API keys"
        case .anthropic: return "console.anthropic.com → API Keys"
        case .gemini: return "aistudio.google.com → Get API key"
        case .openRouter: return "openrouter.ai → Keys"
        case .oMLX: return "Only if you started oMLX with an API key"
        default: return "Optional for local servers"
        }
    }
}

/// How much a reasoning model may think before it answers.
///
/// Servers expose this differently: oMLX takes a hard token budget (it closes
/// the thinking block when the budget runs out, and the model then answers),
/// chat templates take `reasoning_effort` (Qwen 3.8 and gpt-oss; Qwen 3.8
/// defaults to its highest level, "xhigh", when none is sent) or only
/// switch thinking on or off (`enable_thinking`), OpenAI and
/// OpenRouter take an effort level and Gemini a token budget. Models that
/// don't think ignore the setting, except that OpenAI rejects an effort level
/// for its non-reasoning models.
public enum ThinkingEffort: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Send nothing; the model thinks as much as it likes.
    case full
    case medium, low
    case off

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .full: return "Full (model default)"
        case .medium: return "Medium"
        case .low: return "Low"
        case .off: return "Off"
        }
    }

    /// Thinking tokens allowed where a server takes a budget.
    public var tokenBudget: Int? {
        switch self {
        case .full: return nil
        case .medium: return 8_192
        case .low: return 2_048
        case .off: return 0
        }
    }

    /// The levels a provider can act on. Diffactly doesn't turn on Claude's
    /// extended thinking, so Anthropic has nothing to reduce; OpenAI's
    /// reasoning models don't all accept switching it off.
    public static func options(for kind: LLMProviderKind) -> [ThinkingEffort] {
        switch kind {
        case .anthropic: return []
        case .openAI: return [.full, .medium, .low]
        default: return allCases
        }
    }
}

public struct LLMMessage: Equatable, Sendable, Codable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var role: Role
    public var content: String
    public init(_ role: Role, _ content: String) { self.role = role; self.content = content }
}

/// Where and how to send a request.
public struct LLMEndpoint: Sendable, Equatable {
    public var kind: LLMProviderKind
    public var baseURL: String
    public var apiKey: String
    public var model: String
    public var thinking: ThinkingEffort

    public init(kind: LLMProviderKind, baseURL: String, apiKey: String = "", model: String, thinking: ThinkingEffort = .full) {
        self.kind = kind
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.thinking = thinking
    }
}

/// One piece of a streamed answer.
public enum LLMDelta: Equatable, Sendable {
    case text(String)
    /// Thinking that the server sends apart from the answer (Anthropic
    /// thinking blocks, Gemini thoughts, `reasoning_content` from LM Studio,
    /// oMLX, Ollama, OpenRouter, …). Inline `<think>` tags arrive as `.text`.
    case reasoning(String)
    /// The model stopped because it reached the output token limit.
    case truncated
}

public struct LLMRequest: Sendable, Equatable {
    /// Large, unchanging background (reference documents) sent ahead of the
    /// system instructions so providers can cache it between requests:
    /// Anthropic gets an explicit cache breakpoint after it, the others reuse
    /// it through automatic prefix caching.
    public var context: String
    public var system: String
    public var messages: [LLMMessage]
    /// nil leaves sampling to the provider's default.
    public var temperature: Double?
    public var maxTokens: Int

    public init(context: String = "", system: String, messages: [LLMMessage], temperature: Double? = nil, maxTokens: Int = 8192) {
        self.context = context
        self.system = system
        self.messages = messages
        self.temperature = temperature
        self.maxTokens = maxTokens
    }

    /// Context and instructions as one system prompt (context first).
    var combinedSystem: String {
        [context, system].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

/// How many tokens a request may generate.
///
/// Reasoning models spend the output budget on thinking before they write a
/// word of the answer, and some (Qwen 3, for one) draft the whole answer and
/// check it point by point inside that thinking, so the thinking alone can
/// run to several times the answer's length. Cloud providers bill for output
/// and reject limits above a model's maximum, so they get a moderate budget
/// sized to the answer. A local server costs nothing extra per token, so it
/// gets as much as its context window leaves after the prompt (within a
/// generous cap, so a model stuck in a loop still stops eventually).
public enum OutputBudget {
    /// Never less than this for a local model, whatever the answer's size.
    public static let localFloor = 32_768
    /// Local room for thinking, as a multiple of the expected answer.
    public static let localAnswerMultiple = 8
    /// Left free in the context window for chat-template tokens and
    /// estimation error (prompts are estimated at four characters per token).
    public static let windowMargin = 512

    /// - Parameters:
    ///   - answerTokens: rough length of the expected answer.
    ///   - cloud: the budget to use for cloud providers.
    ///   - inputTokens: rough size of the prompt.
    ///   - contextLength: the model's whole context window, when known.
    public static func tokens(answerTokens: Int, cloud: Int, inputTokens: Int, contextLength: Int?, isLocal: Bool) -> Int {
        guard isLocal else { return cloud }
        let generous = max(cloud, localFloor, answerTokens * localAnswerMultiple)
        guard let window = contextLength, window > 0 else { return generous }
        // Asking for more than fits makes some servers reject the request.
        return max(1_024, min(generous, window - inputTokens - windowMargin))
    }
}

/// A model a server offers, with its context window when the server says.
public struct LLMModelInfo: Equatable, Sendable, Codable {
    public var id: String
    /// Maximum input tokens, if reported (oMLX/vLLM `max_model_len`,
    /// OpenRouter `context_length`, Gemini `inputTokenLimit`, …).
    public var contextLength: Int?

    public init(id: String, contextLength: Int? = nil) {
        self.id = id
        self.contextLength = contextLength
    }
}

public enum LLMError: LocalizedError, Equatable {
    case invalidURL(String)
    case missingModel
    case missingAPIKey(String)
    case http(status: Int, message: String)
    case emptyResponse
    case cannotConnect(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let s): return "“\(s)” isn’t a valid server address."
        case .missingModel: return "Choose a model first. Use Fetch Models in Settings or type a model name."
        case .missingAPIKey(let name): return "\(name) needs an API key. Add one in Settings → AI."
        case .http(let status, let message):
            let hint: String
            switch status {
            case 401, 403: hint = " Check the API key."
            case 404: hint = " Check the server address and model name."
            case 429: hint = " The provider is rate-limiting requests; try again shortly."
            default: hint = ""
            }
            return "The server answered \(status): \(message)\(hint)"
        case .emptyResponse: return "The model returned no text."
        case .cannotConnect(let s): return "Couldn’t reach \(s). Is the server running?"
        }
    }
}

/// A minimal streaming client for chat models.
public struct LLMClient: Sendable {
    public var endpoint: LLMEndpoint
    public var session: URLSession

    public init(endpoint: LLMEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    // MARK: Streaming completion

    /// Streams the model's answer as it arrives: text, reasoning ("thinking")
    /// from models that expose it separately, and a note when the output was
    /// cut off by the token limit.
    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try makeChatRequest(request, stream: true)
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    try await Self.check(response, bytes: bytes)
                    var parser = SSEParser(style: endpoint.kind.apiStyle)
                    var produced = false
                    lines: for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        for event in try parser.consume(line) {
                            switch event {
                            case .text(let t):
                                produced = true
                                continuation.yield(.text(t))
                            case .reasoning(let t):
                                produced = true
                                continuation.yield(.reasoning(t))
                            case .truncated:
                                continuation.yield(.truncated)
                            case .done:
                                break lines
                            }
                        }
                    }
                    if !produced && !Task.isCancelled { throw LLMError.emptyResponse }
                    continuation.finish()
                } catch let error as URLError where [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut].contains(error.code) {
                    continuation.finish(throwing: LLMError.cannotConnect(endpoint.baseURL))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Convenience: the whole answer (text only) as one string.
    public func complete(_ request: LLMRequest) async throws -> String {
        var text = ""
        for try await delta in stream(request) {
            if case .text(let t) = delta { text += t }
        }
        return text
    }

    // MARK: Models

    /// Model identifiers the server offers, sorted.
    public func listModels() async throws -> [String] {
        try await listModelInfo().map(\.id)
    }

    /// Models with their context windows where the server reports them.
    public func listModelInfo() async throws -> [LLMModelInfo] {
        let request = try makeModelsRequest()
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where [.cannotConnectToHost, .cannotFindHost, .timedOut].contains(error.code) {
            throw LLMError.cannotConnect(endpoint.baseURL)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LLMError.http(status: http.statusCode, message: Self.errorMessage(from: data))
        }
        return try Self.parseModelInfo(data, style: endpoint.kind.apiStyle)
    }

    static func parseModels(_ data: Data, style: LLMAPIStyle) throws -> [String] {
        try parseModelInfo(data, style: style).map(\.id)
    }

    static func parseModelInfo(_ data: Data, style: LLMAPIStyle) throws -> [LLMModelInfo] {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var ids = Set<String>()
        var lengths: [String: Int] = [:]
        func add(_ id: String, _ item: [String: Any]) {
            ids.insert(id)
            if let n = contextLength(item) { lengths[id] = n }
        }
        func contextLength(_ item: [String: Any]) -> Int? {
            for key in ["max_model_len", "context_length", "context_window", "max_context_length", "max_input_tokens", "inputTokenLimit"] {
                if let n = item[key] as? Int, n > 0 { return n }
                if let n = item[key] as? Double, n > 0 { return Int(n) }
            }
            if let top = item["top_provider"] as? [String: Any], let n = top["context_length"] as? Int { return n }
            return nil
        }
        switch style {
        case .openAI, .anthropic:
            for item in json["data"] as? [[String: Any]] ?? [] {
                if let id = item["id"] as? String { add(id, item) }
            }
            // Ollama's native /api/tags shape, in case the base URL omits /v1.
            for item in json["models"] as? [[String: Any]] ?? [] {
                if let id = (item["model"] ?? item["name"]) as? String { add(id, item) }
            }
        case .gemini:
            for item in json["models"] as? [[String: Any]] ?? [] {
                let methods = item["supportedGenerationMethods"] as? [String] ?? ["generateContent"]
                guard methods.contains("generateContent"), let name = item["name"] as? String else { continue }
                add(name.hasPrefix("models/") ? String(name.dropFirst(7)) : name, item)
            }
        }
        return ids.sorted().map { LLMModelInfo(id: $0, contextLength: lengths[$0]) }
    }

    // MARK: Request building

    func url(_ path: String) throws -> URL {
        var base = endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path), url.scheme == "http" || url.scheme == "https", url.host != nil else {
            throw LLMError.invalidURL(endpoint.baseURL)
        }
        return url
    }

    func makeModelsRequest() throws -> URLRequest {
        var request: URLRequest
        switch endpoint.kind.apiStyle {
        case .gemini:
            request = URLRequest(url: try url("/models?pageSize=1000"))
        case .openAI, .anthropic:
            request = URLRequest(url: try url("/models"))
        }
        request.timeoutInterval = 15
        applyAuth(&request)
        return request
    }

    func makeChatRequest(_ req: LLMRequest, stream: Bool) throws -> URLRequest {
        let model = endpoint.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw LLMError.missingModel }
        if endpoint.kind.requiresAPIKey, endpoint.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            throw LLMError.missingAPIKey(endpoint.kind.title)
        }
        var body: [String: Any]
        var request: URLRequest
        switch endpoint.kind.apiStyle {
        case .openAI:
            request = URLRequest(url: try url("/chat/completions"))
            var messages: [[String: Any]] = []
            // One system message: several trip up some local chat templates.
            if !req.combinedSystem.isEmpty { messages.append(["role": "system", "content": req.combinedSystem]) }
            messages += req.messages.map { ["role": $0.role.rawValue, "content": $0.content] }
            body = ["model": model, "messages": messages, "stream": stream]
            // OpenAI's newer models reject `max_tokens`; local servers ignore the newer name.
            if endpoint.kind == .openAI { body["max_completion_tokens"] = req.maxTokens } else { body["max_tokens"] = req.maxTokens }
            if let t = req.temperature { body["temperature"] = t }
            addOpenAIStyleThinking(to: &body)
        case .anthropic:
            request = URLRequest(url: try url("/messages"))
            body = [
                "model": model,
                "max_tokens": req.maxTokens,
                "messages": req.messages.map { ["role": $0.role.rawValue, "content": $0.content] },
                "stream": stream,
            ]
            var system: [[String: Any]] = []
            if !req.context.isEmpty {
                // Cache the reference documents; regenerating reuses them.
                system.append(["type": "text", "text": req.context, "cache_control": ["type": "ephemeral"]])
            }
            if !req.system.isEmpty { system.append(["type": "text", "text": req.system]) }
            if !system.isEmpty { body["system"] = system }
            if let t = req.temperature { body["temperature"] = min(1, t) }
        case .gemini:
            let path = "/models/\(model):" + (stream ? "streamGenerateContent?alt=sse" : "generateContent")
            request = URLRequest(url: try url(path))
            body = [
                "contents": req.messages.map { ["role": $0.role == .assistant ? "model" : "user", "parts": [["text": $0.content]]] },
            ]
            let parts = [req.context, req.system].filter { !$0.isEmpty }.map { ["text": $0] }
            if !parts.isEmpty { body["systemInstruction"] = ["parts": parts] }
            var config: [String: Any] = ["maxOutputTokens": req.maxTokens]
            if let t = req.temperature { config["temperature"] = t }
            if let budget = effectiveThinking?.tokenBudget { config["thinkingConfig"] = ["thinkingBudget": budget] }
            body["generationConfig"] = config
        }
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if stream { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        applyAuth(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The thinking limit to send, or nil to leave the model's default.
    var effectiveThinking: ThinkingEffort? {
        let effort = endpoint.thinking
        return effort != .full && ThinkingEffort.options(for: endpoint.kind).contains(effort) ? effort : nil
    }

    /// Each OpenAI-compatible server names the thinking controls differently;
    /// servers ignore the fields they don't know.
    func addOpenAIStyleThinking(to body: inout [String: Any]) {
        guard let effort = effectiveThinking else { return }
        switch endpoint.kind {
        case .openAI:
            body["reasoning_effort"] = effort.rawValue
        case .openRouter:
            body["reasoning"] = effort == .off ? ["enabled": false] : ["effort": effort.rawValue]
        default:
            if effort == .off {
                // Qwen, DeepSeek and similar chat templates (oMLX, vLLM, llama.cpp).
                body["chat_template_kwargs"] = ["enable_thinking": false]
            } else {
                // Templates with effort levels (Qwen 3.8, gpt-oss) and Ollama.
                body["reasoning_effort"] = effort.rawValue
                // oMLX also caps thinking tokens, which works for any
                // thinking model, Qwen included.
                if endpoint.kind == .oMLX, let budget = effort.tokenBudget { body["thinking_budget"] = budget }
            }
        }
    }

    func applyAuth(_ request: inout URLRequest) {
        let key = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch endpoint.kind.apiStyle {
        case .anthropic:
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
        case .gemini:
            if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-goog-api-key") }
        case .openAI:
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            if endpoint.kind == .openRouter {
                request.setValue("Diffactly", forHTTPHeaderField: "X-Title")
            }
        }
    }

    // MARK: Errors

    static func check(_ response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > 64_000 { break }
        }
        throw LLMError.http(status: http.statusCode, message: errorMessage(from: data))
    }

    /// Pulls the human-readable message out of the providers' error JSON.
    static func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) {
            let object = (json as? [[String: Any]])?.first ?? json as? [String: Any]
            if let error = object?["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let message = object?["error"] as? String { return message }
            if let message = object?["message"] as? String { return message }
        }
        let text = String(decoding: data.prefix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "no details" : text
    }
}

// MARK: - Server-sent events

/// Turns the `data:` lines of a streaming response into deltas.
struct SSEParser {
    enum Event: Equatable { case text(String), reasoning(String), truncated, done }

    let style: LLMAPIStyle

    mutating func consume(_ rawLine: String) throws -> [Event] {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return [.done] }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let error = json["error"] {
            let message = (error as? [String: Any])?["message"] as? String ?? String(describing: error)
            throw LLMError.http(status: 500, message: message)
        }
        var events: [Event] = []
        switch style {
        case .openAI:
            guard let choice = (json["choices"] as? [[String: Any]])?.first else { return [] }
            let delta = choice["delta"] as? [String: Any] ?? choice["message"] as? [String: Any]
            // Servers disagree on the name of the reasoning field.
            for key in ["reasoning_content", "reasoning"] {
                if let thinking = delta?[key] as? String, !thinking.isEmpty { events.append(.reasoning(thinking)); break }
            }
            if let text = delta?["content"] as? String, !text.isEmpty { events.append(.text(text)) }
            if choice["finish_reason"] as? String == "length" { events.append(.truncated) }
        case .anthropic:
            switch json["type"] as? String {
            case "content_block_delta":
                let delta = json["delta"] as? [String: Any]
                switch delta?["type"] as? String {
                case "text_delta":
                    if let text = delta?["text"] as? String { events.append(.text(text)) }
                case "thinking_delta":
                    if let thinking = delta?["thinking"] as? String { events.append(.reasoning(thinking)) }
                default:
                    break
                }
            case "message_delta":
                if (json["delta"] as? [String: Any])?["stop_reason"] as? String == "max_tokens" { events.append(.truncated) }
            case "message_stop":
                events.append(.done)
            default:
                break
            }
        case .gemini:
            guard let candidate = (json["candidates"] as? [[String: Any]])?.first else { return [] }
            let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            let thoughts = parts.filter { ($0["thought"] as? Bool) == true }.compactMap { $0["text"] as? String }.joined()
            let text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
            if !thoughts.isEmpty { events.append(.reasoning(thoughts)) }
            if !text.isEmpty { events.append(.text(text)) }
            if candidate["finishReason"] as? String == "MAX_TOKENS" { events.append(.truncated) }
        }
        return events
    }
}
