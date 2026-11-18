import Foundation
import DiffactlyCore

/// How the output token limit cut a run short.
enum RewriteTruncation: String, Equatable {
    /// The budget ran out while the model was still thinking: no answer at all.
    case thinking
    /// The answer started but is cut off.
    case answer
    /// The second pass ran out while thinking, so the result is the first draft.
    case secondPass
}

/// Runs one rewrite: a draft and, depending on the settings, a checking pass.
/// Shared by the AI sheet and inline suggestions, which only differ in where
/// the streaming text and progress go.
@MainActor
enum RewriteRunner {

    enum Stage: Equatable { case drafting, auditing }

    /// Progress reported while a rewrite streams.
    enum Update {
        case stage(Stage)
        /// The cleaned answer so far.
        case text(String)
        /// Whether the model is reasoning before answering, and how much it has written.
        case thinking(Bool, characters: Int)
        /// The output token limit of the request now running.
        case budget(Int)
    }

    struct Job {
        var client: LLMClient
        var first: RewritePrompt.Messages
        var audit: (String, [String], [String]) -> RewritePrompt.Messages
        var secondPass: SecondPassMode
        var checkTells: Bool
        /// The rewrite follows the academic rules, so the draft is also
        /// checked for academic padding and for any em dash.
        var academic: Bool = false
        var sourceUsesDashes: Bool
        var sourceText: String = ""
        var strength: RewriteStrength = .moderate
        var temperature: Double?
        var maxTokens: Int
    }

    struct Outcome {
        var text: String
        var truncation: RewriteTruncation?
        var didAudit: Bool
    }

    /// Streams the draft, then runs the second pass when it's always on, or
    /// when the scan still finds tells or missing numbers. Throws `CancellationError` when cancelled.
    static func run(_ job: Job, update: @escaping (Update) -> Void) async throws -> Outcome {
        update(.stage(.drafting))
        let (draft, draftCut) = try await stream(job.client, request(job.first, job), update: update)
        try Task.checkCancellation()
        var truncation: RewriteTruncation? = draftCut ? (draft.isEmpty ? .thinking : .answer) : nil

        let scan = AITells.scan(draft)
        var flagged = scan.topPhrases.map(\.phrase)
        if job.checkTells, !job.sourceUsesDashes, scan.emDashes > 0 { flagged.append("—") }
        var academicFlagged: [String] = []
        if job.academic {
            academicFlagged = AcademicHumanizer.flaggedPhrases(in: draft).filter { !flagged.contains($0) }
            if scan.emDashes > 0, !flagged.contains("—") { academicFlagged.append("—") }
            flagged += academicFlagged
        }
        let missingNumbers = job.sourceText.isEmpty ? [] : AITells.missingNumbers(from: job.sourceText, in: draft)
        let needsAutoAudit = !missingNumbers.isEmpty || !academicFlagged.isEmpty
            || (job.checkTells && (!flagged.isEmpty || scan.hasUniformCadence))
        let runAudit = !draft.isEmpty && (job.secondPass == .always || (job.secondPass == .auto && needsAutoAudit))
        guard runAudit else { return Outcome(text: draft, truncation: truncation, didAudit: false) }

        update(.stage(.auditing))
        let auditPrompt = job.audit(draft, flagged, missingNumbers)
        let (revised, auditCut) = try await stream(job.client, request(auditPrompt, job), keepUntilText: true, update: update)
        try Task.checkCancellation()
        // An empty audit keeps the draft.
        let text = revised.isEmpty ? draft : revised
        if revised.isEmpty { update(.text(draft)) }
        if auditCut { truncation = revised.isEmpty ? (truncation ?? .secondPass) : .answer }
        return Outcome(text: text, truncation: truncation, didAudit: true)
    }

    static func request(_ m: RewritePrompt.Messages, temperature: Double?, maxTokens: Int) -> LLMRequest {
        LLMRequest(context: m.context, system: m.system, messages: [LLMMessage(.user, m.user)], temperature: temperature, maxTokens: maxTokens)
    }

    private static func request(_ m: RewritePrompt.Messages, _ job: Job) -> LLMRequest {
        request(m, temperature: job.temperature, maxTokens: job.maxTokens)
    }

    /// Streams one request, reporting the cleaned text and the "thinking"
    /// state, and returns the final cleaned text. With `keepUntilText`, no
    /// text is reported until the new answer starts (a second pass shouldn't
    /// blank the draft while the model thinks).
    static func stream(_ client: LLMClient, _ request: LLMRequest, keepUntilText: Bool = false, update: (Update) -> Void) async throws -> (text: String, truncated: Bool) {
        var raw = ""
        var reasoning = 0
        var truncated = false
        var lastUpdate = Date.distantPast
        update(.budget(request.maxTokens))
        update(.thinking(false, characters: 0))
        func publish() {
            let cleaned = RewritePrompt.clean(raw)
            if !(keepUntilText && cleaned.isEmpty) { update(.text(cleaned)) }
            let inlineThinking = raw.contains("<think>") && !raw.contains("</think>")
            update(.thinking(cleaned.isEmpty && (reasoning > 0 || inlineThinking), characters: reasoning))
            lastUpdate = Date()
        }
        for try await delta in client.stream(request) {
            switch delta {
            case .text(let t): raw += t
            case .reasoning(let t): reasoning += t.count
            case .truncated: truncated = true
            }
            // Repainting on every token is wasteful; ~20 fps is plenty.
            if Date().timeIntervalSince(lastUpdate) > 0.05 { publish() }
        }
        publish()
        update(.thinking(false, characters: reasoning))
        return (RewritePrompt.clean(raw), truncated)
    }

    /// Local servers get room for long thinking; see `OutputBudget`.
    static func outputBudget(answerTokens: Int, cloud: Int, input: RewritePrompt.Messages, provider: AIProvider) -> Int {
        OutputBudget.tokens(answerTokens: answerTokens, cloud: cloud, inputTokens: input.estimatedTokens,
                            contextLength: provider.contextLength, isLocal: provider.kind.isLocal)
    }

    /// Output budget for rewriting one passage.
    static func passageBudget(_ passage: String, input: RewritePrompt.Messages, provider: AIProvider) -> Int {
        outputBudget(answerTokens: passage.count / 4,
                     cloud: min(16_000, max(6_144, passage.count / 2 + 4_096)),
                     input: input, provider: provider)
    }
}
