import Foundation
import DiffactlyCore

/// What the AI sheet is doing.
enum AITask: String, CaseIterable, Identifiable {
    /// Humanize / paraphrase / merge the texts (or one passage) into a new version.
    case rewrite
    /// Explain the main differences between the two texts.
    case summary

    var id: String { rawValue }
    var title: String { self == .rewrite ? "Rewrite" : "Summarize Differences" }
}

/// What a rewrite works on.
enum RewriteTarget: Hashable {
    case left, both, right
    /// The passage selected in one of the editors.
    case selection

    init(_ source: RewriteSource) {
        switch source {
        case .left: self = .left
        case .both: self = .both
        case .right: self = .right
        }
    }

    var source: RewriteSource? {
        switch self {
        case .left: return .left
        case .both: return .both
        case .right: return .right
        case .selection: return nil
        }
    }
}

/// When to run the second, checking pass of a rewrite.
enum SecondPassMode: String, CaseIterable, Identifiable {
    case off
    /// Only when the scanner still finds AI tells in the draft.
    case auto
    case always

    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .auto: return "If tells remain"
        case .always: return "Always"
        }
    }
}

/// The AI sheet of one window: its choices, reference documents, the
/// streaming results and what was last written into an editor (so it can be
/// reverted).
@MainActor
final class RewriteSession: ObservableObject {
    enum Phase: Equatable {
        case idle, drafting, auditing, summarizing, finished
        case failed(String)

        var isRunning: Bool { self == .drafting || self == .auditing || self == .summarizing }
    }

    /// A passage selected in an editor, captured when the sheet opened.
    struct Passage: Equatable {
        var side: DiffDocument.Side
        var range: NSRange
        var text: String
    }

    struct Applied: Equatable {
        var side: DiffDocument.Side
        var previousText: String
    }

    struct HistoryItem: Identifiable, Equatable {
        let id = UUID()
        var task: AITask
        var text: String
        var label: String
        var date: Date
        /// Set when the result replaces a passage rather than a whole text.
        var passage: Passage?
    }

    // MARK: Choices (remembered between launches)

    @Published var task: AITask = .rewrite
    @Published var source: RewriteSource { didSet { defaults.set(source.rawValue, forKey: Keys.source) } }
    /// Rewrite only `passage` instead of whole texts.
    @Published var rewritesSelection = false
    @Published var leftWeight: Double { didSet { defaults.set(leftWeight, forKey: Keys.weight) } }
    @Published var strength: RewriteStrength { didSet { defaults.set(strength.rawValue, forKey: Keys.strength) } }
    @Published var promptID: String { didSet { defaults.set(promptID, forKey: Keys.prompt) } }
    @Published var providerID: UUID? { didSet { defaults.set(providerID?.uuidString, forKey: Keys.provider) } }
    @Published var avoidAITells: Bool { didSet { defaults.set(avoidAITells, forKey: Keys.avoid) } }
    @Published var secondPass: SecondPassMode { didSet { defaults.set(secondPass.rawValue, forKey: Keys.secondPassMode) } }
    @Published var preserveFormatting: Bool { didSet { defaults.set(preserveFormatting, forKey: Keys.formatting) } }
    @Published var useCustomTemperature: Bool { didSet { defaults.set(useCustomTemperature, forKey: Keys.useTemp) } }
    @Published var temperature: Double { didSet { defaults.set(temperature, forKey: Keys.temp) } }
    @Published var summaryDetail: SummaryDetail { didSet { defaults.set(summaryDetail.rawValue, forKey: Keys.summaryDetail) } }
    @Published var summaryFocus: SummaryFocus { didSet { defaults.set(summaryFocus.rawValue, forKey: Keys.summaryFocus) } }
    /// When rewriting a passage, also show the model the other side.
    @Published var includeOtherSide: Bool { didSet { defaults.set(includeOtherSide, forKey: Keys.includeOther) } }
    /// One-off notes for this window; not persisted.
    @Published var extraNotes = ""

    /// Supplementary documents for this window's session.
    let references = ReferenceLibrary()

    // MARK: Results

    /// The selection captured when the sheet opened (nil when nothing was selected).
    @Published private(set) var passage: Passage?
    /// The rewritten text or passage (editable).
    @Published var output = ""
    /// The passage `output` replaces; nil when `output` is a whole text.
    @Published private(set) var outputPassage: Passage?
    /// The difference summary, as Markdown.
    @Published var summary = ""
    @Published private(set) var phase: Phase = .idle
    /// Which task the current or last run belonged to.
    @Published private(set) var runTask: AITask?
    /// The model is reasoning and hasn't started its answer yet.
    @Published private(set) var isThinking = false
    @Published private(set) var reasoningCharacters = 0
    /// How the output token limit cut a run short.
    enum Truncation: Equatable {
        /// The budget ran out while the model was still thinking: no answer at all.
        case thinking
        /// The answer started but is cut off.
        case answer
        /// The second pass ran out while thinking, so the result is the first draft.
        case secondPass
    }

    /// Set when the last run hit the output token limit.
    @Published private(set) var truncation: Truncation?
    /// The output token limit of the last run.
    @Published private(set) var outputBudget = 0
    @Published private(set) var startedAt: Date?
    @Published private(set) var duration: TimeInterval?
    /// Whether the last rewrite ran the checking pass.
    @Published private(set) var didAudit = false
    @Published private(set) var applied: Applied?
    @Published private(set) var outputTells: AITells.Report?
    @Published private(set) var history: [HistoryItem] = []
    /// A problem using the result (e.g. the passage changed in the meantime).
    @Published var applyError: String?

    private var job: Task<Void, Never>?
    private var raw = ""
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let source = "rewrite.source"
        static let weight = "rewrite.leftWeight"
        static let strength = "rewrite.strength"
        static let prompt = "rewrite.prompt"
        static let provider = "rewrite.provider"
        static let avoid = "rewrite.avoidAITells"
        static let secondPass = "rewrite.secondPass"           // legacy Bool
        static let secondPassMode = "rewrite.secondPassMode"
        static let formatting = "rewrite.preserveFormatting"
        static let useTemp = "rewrite.useCustomTemperature"
        static let temp = "rewrite.temperature"
        static let summaryDetail = "summary.detail"
        static let summaryFocus = "summary.focus"
        static let includeOther = "rewrite.includeOtherSide"
    }

    init() {
        let d = UserDefaults.standard
        source = RewriteSource(rawValue: d.string(forKey: Keys.source) ?? "") ?? .both
        leftWeight = d.object(forKey: Keys.weight) as? Double ?? 0.5
        strength = RewriteStrength(rawValue: d.string(forKey: Keys.strength) ?? "") ?? .moderate
        promptID = d.string(forKey: Keys.prompt) ?? RewritePreset.humanizeID
        providerID = d.string(forKey: Keys.provider).flatMap(UUID.init(uuidString:))
        avoidAITells = d.object(forKey: Keys.avoid) as? Bool ?? true
        if let mode = d.string(forKey: Keys.secondPassMode).flatMap(SecondPassMode.init(rawValue:)) {
            secondPass = mode
        } else {
            secondPass = d.bool(forKey: Keys.secondPass) ? .always : .auto
        }
        preserveFormatting = d.object(forKey: Keys.formatting) as? Bool ?? true
        useCustomTemperature = d.bool(forKey: Keys.useTemp)
        temperature = d.object(forKey: Keys.temp) as? Double ?? 0.8
        summaryDetail = SummaryDetail(rawValue: d.string(forKey: Keys.summaryDetail) ?? "") ?? .brief
        summaryFocus = SummaryFocus(rawValue: d.string(forKey: Keys.summaryFocus) ?? "") ?? .meaning
        includeOtherSide = d.object(forKey: Keys.includeOther) as? Bool ?? true
    }

    // MARK: Opening

    /// Called when the sheet appears: picks the tab and captures the selection.
    func prepare(for document: DiffDocument) {
        task = document.aiTask
        if let selection = document.selection, !selection.text.isEmpty {
            let current = document.text(for: selection.side)
            let range = SelectionRewrite.locate(selection.text, in: current, near: selection.range) ?? selection.range
            passage = Passage(side: selection.side, range: range, text: selection.text)
        } else {
            passage = nil
        }
        if document.aiStartsWithSelection, passage != nil {
            task = .rewrite
            rewritesSelection = true
        } else if passage == nil {
            rewritesSelection = false
        }
        // Otherwise keep the last choice: someone who rewrote a selection last
        // time and has one now most likely wants that again.
        document.aiStartsWithSelection = false
    }

    var target: RewriteTarget {
        get { rewritesSelection ? .selection : RewriteTarget(source) }
        set {
            if let source = newValue.source {
                self.source = source
                rewritesSelection = false
            } else if passage != nil {
                rewritesSelection = true
            }
        }
    }

    // MARK: Resolving choices

    /// The chosen provider, or the first configured one.
    func resolvedProvider(in store: AIStore) -> AIProvider? {
        store.provider(id: providerID) ?? store.providers.first
    }

    func resolvedPrompt(in store: AIStore) -> RewritePreset {
        store.prompt(id: promptID) ?? RewritePreset.builtIns[0]
    }

    /// Files already open in this window aren't sent again as references.
    func openFileNames(_ document: DiffDocument) -> Set<String> {
        Set([document.leftName, document.rightName].compactMap { $0 })
    }

    func referenceDocuments(for document: DiffDocument) -> [ReferenceDocument] {
        references.documents(excludingFileNames: openFileNames(document))
    }

    /// LaTeX when the file names say so; otherwise detected from the text.
    private func markup(_ document: DiffDocument, sides: [DiffDocument.Side]) -> TextMarkup? {
        let names = sides.compactMap { $0 == .left ? document.leftName : document.rightName }
        return names.contains { TextMarkup.detect("", fileName: $0) == .latex } ? .latex : nil
    }

    func rewriteSpec(document: DiffDocument, store: AIStore) -> RewriteSpec {
        let sides: [DiffDocument.Side] = source == .left ? [.left] : source == .right ? [.right] : [.left, .right]
        return RewriteSpec(
            leftText: document.leftText,
            rightText: document.rightText,
            leftTitle: document.title(for: .left),
            rightTitle: document.title(for: .right),
            source: source,
            leftWeight: leftWeight,
            strength: strength,
            instructions: resolvedPrompt(in: store).instructions,
            extraNotes: extraNotes,
            avoidAITells: avoidAITells,
            preserveFormatting: preserveFormatting,
            references: referenceDocuments(for: document),
            markup: markup(document, sides: sides)
        )
    }

    func selectionSpec(_ passage: Passage, document: DiffDocument, store: AIStore, withReferences: Bool = true) -> SelectionRewriteSpec {
        let side = passage.side
        return SelectionRewriteSpec(
            documentText: document.text(for: side),
            documentTitle: document.title(for: side),
            fileName: side == .left ? document.leftName : document.rightName,
            range: passage.range,
            otherText: includeOtherSide ? document.text(for: side.other) : nil,
            otherTitle: document.title(for: side.other),
            strength: strength,
            instructions: resolvedPrompt(in: store).instructions,
            extraNotes: extraNotes,
            avoidAITells: avoidAITells,
            references: withReferences ? referenceDocuments(for: document) : [],
            markup: markup(document, sides: [side])
        )
    }

    func summarySpec(document: DiffDocument) -> DiffSummarySpec {
        DiffSummarySpec(
            leftText: document.leftText,
            rightText: document.rightText,
            leftTitle: document.title(for: .left),
            rightTitle: document.title(for: .right),
            result: document.result,
            detail: summaryDetail,
            focus: summaryFocus,
            extraNotes: extraNotes,
            references: referenceDocuments(for: document)
        )
    }

    /// Exactly what the current task would send.
    func previewMessages(document: DiffDocument, store: AIStore) -> RewritePrompt.Messages {
        switch task {
        case .rewrite:
            if rewritesSelection, let passage { return SelectionRewrite.messages(for: selectionSpec(passage, document: document, store: store)) }
            return RewritePrompt.messages(for: rewriteSpec(document: document, store: store))
        case .summary:
            return DiffSummaryPrompt.messages(for: summarySpec(document: document))
        }
    }

    /// Rough input size. Cheap enough to call on every redraw: references are
    /// counted by length and the summary's diff isn't formatted.
    func estimatedInputTokens(document: DiffDocument, store: AIStore) -> Int {
        let references = self.references.characterCount(excludingFileNames: openFileNames(document)) / 4
        switch task {
        case .rewrite:
            if rewritesSelection, let passage {
                return SelectionRewrite.messages(for: selectionSpec(passage, document: document, store: store, withReferences: false)).estimatedTokens + references
            }
            var spec = rewriteSpec(document: document, store: store)
            spec.references = []
            return RewritePrompt.messages(for: spec).estimatedTokens + references
        case .summary:
            let spec = summarySpec(document: document)
            let stats = spec.result.stats
            let texts = DiffSummaryPrompt.includesFullTexts(spec) ? spec.leftText.count + spec.rightText.count : 0
            // The diff holds the changed text plus a line of context around each change.
            let diff = min(DiffSummaryPrompt.patchLimit, stats.removedCharacters + stats.addedCharacters + spec.result.hunks.count * 240)
            return (texts + diff + 2_400) / 4 + references
        }
    }

    /// Why the current task can't run right now, or nil when it can.
    func blocker(document: DiffDocument, store: AIStore) -> String? {
        guard let provider = resolvedProvider(in: store) else { return "Add an AI provider in Settings first." }
        if provider.model.trimmingCharacters(in: .whitespaces).isEmpty { return "Choose a model for \(provider.displayName)." }
        let left = !document.leftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let right = !document.rightText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch task {
        case .summary:
            return left && right ? nil : "Put text on both sides to compare."
        case .rewrite:
            if rewritesSelection {
                guard let passage else { return "Select a passage in an editor first." }
                return passage.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "The selection is only whitespace." : nil
            }
            switch source {
            case .left: return left ? nil : "There’s no \(document.title(for: .left).lowercased()) text to rewrite."
            case .right: return right ? nil : "There’s no \(document.title(for: .right).lowercased()) text to rewrite."
            case .both: return left || right ? nil : "There’s no text to rewrite."
            }
        }
    }

    // MARK: Running

    func run(document: DiffDocument, store: AIStore) {
        guard !phase.isRunning, let provider = resolvedProvider(in: store) else { return }
        references.refresh()
        applyError = nil
        switch task {
        case .rewrite:
            if rewritesSelection, let passage {
                runSelectionRewrite(passage, provider: provider, document: document, store: store)
            } else {
                runRewrite(provider: provider, document: document, store: store)
            }
        case .summary:
            runSummary(provider: provider, document: document, store: store)
        }
    }

    private func begin(_ task: AITask, phase: Phase) {
        runTask = task
        self.phase = phase
        startedAt = Date()
        duration = nil
        truncation = nil
        isThinking = false
        reasoningCharacters = 0
    }

    private func runRewrite(provider: AIProvider, document: DiffDocument, store: AIStore) {
        let spec = rewriteSpec(document: document, store: store)
        let sourceText = (spec.source != .right ? spec.leftText : "") + (spec.source != .left ? spec.rightText : "")
        let markup = spec.markup ?? TextMarkup.detect(sourceText)
        let messages = RewritePrompt.messages(for: spec)
        // Room for the answer (≈ 2× the source) plus a reasoning model's thinking.
        let maxTokens = Self.outputBudget(
            answerTokens: sourceText.count / 4,
            cloud: min(32_000, max(8_192, sourceText.count / 2 + 4_096)),
            input: messages, provider: provider)
        startRewrite(
            first: messages,
            audit: { draft, flagged in RewritePrompt.auditMessages(draft: draft, spec: spec, flagged: flagged) },
            sourceUsesDashes: markup.usesEmDashes(sourceText),
            maxTokens: maxTokens,
            passage: nil,
            label: "\(resolvedPrompt(in: store).name) · \(provider.model)",
            client: LLMClient(endpoint: store.endpoint(for: provider))
        )
    }

    private func runSelectionRewrite(_ passage: Passage, provider: AIProvider, document: DiffDocument, store: AIStore) {
        // The editor may have moved the passage since the sheet opened.
        var passage = passage
        if let range = SelectionRewrite.locate(passage.text, in: document.text(for: passage.side), near: passage.range) {
            passage.range = range
            self.passage = passage
        }
        let spec = selectionSpec(passage, document: document, store: store)
        let markup = spec.markup ?? TextMarkup.detect(spec.documentText, fileName: spec.fileName)
        let messages = SelectionRewrite.messages(for: spec)
        startRewrite(
            first: messages,
            audit: { draft, flagged in SelectionRewrite.auditMessages(draft: draft, spec: spec, flagged: flagged) },
            sourceUsesDashes: markup.usesEmDashes(passage.text),
            maxTokens: Self.outputBudget(
                answerTokens: passage.text.count / 4,
                cloud: min(16_000, max(6_144, passage.text.count / 2 + 4_096)),
                input: messages, provider: provider),
            passage: passage,
            label: "\(resolvedPrompt(in: store).name) (selection) · \(provider.model)",
            client: LLMClient(endpoint: store.endpoint(for: provider))
        )
    }

    /// Shared by whole-text and passage rewrites: a draft, then optionally a
    /// checking pass.
    private func startRewrite(
        first: RewritePrompt.Messages,
        audit: @escaping (String, [String]) -> RewritePrompt.Messages,
        sourceUsesDashes: Bool,
        maxTokens: Int,
        passage: Passage?,
        label: String,
        client: LLMClient
    ) {
        let temperature = useCustomTemperature ? temperature : nil
        let mode = secondPass
        let checkTells = avoidAITells

        output = ""
        outputPassage = passage
        outputTells = nil
        didAudit = false
        begin(.rewrite, phase: .drafting)
        job = Task { [weak self] in
            do {
                guard let (draft, draftCut) = try await self?.stream(client, Self.request(first, temperature: temperature, maxTokens: maxTokens), into: \.output),
                      let self, !Task.isCancelled else { return }
                if draftCut { self.truncation = draft.isEmpty ? .thinking : .answer }

                // Second pass: always, or only when the scan still finds tells.
                let scan = AITells.scan(draft)
                var flagged = scan.topPhrases.map(\.phrase)
                if checkTells, !sourceUsesDashes, scan.emDashes > 0 { flagged.append("—") }
                let runAudit = !draft.isEmpty && (mode == .always || (mode == .auto && checkTells && !flagged.isEmpty))
                if runAudit {
                    self.phase = .auditing
                    self.didAudit = true
                    let (revised, auditCut) = try await self.stream(client, Self.request(audit(draft, flagged), temperature: temperature, maxTokens: maxTokens), into: \.output, keepUntilText: true)
                    // An empty or cancelled audit keeps the draft.
                    if revised.isEmpty { self.output = draft }
                    if auditCut { self.truncation = revised.isEmpty ? (self.truncation ?? .secondPass) : .answer }
                }
                guard !Task.isCancelled else { return }
                self.finish(label: label)
            } catch {
                guard let self else { return }
                if Task.isCancelled { self.finish(label: label); return }
                self.fail(error)
            }
        }
    }

    private func runSummary(provider: AIProvider, document: DiffDocument, store: AIStore) {
        let spec = summarySpec(document: document)
        summary = ""
        begin(.summary, phase: .summarizing)
        // Nothing to ask a model about.
        if spec.result.isIdentical {
            summary = "**In short:** the two texts are identical\(spec.result.rows.contains(where: \.hasIgnoredDifferences) ? " once the current ignore options are applied" : "")."
            finish(label: nil)
            return
        }
        let client = LLMClient(endpoint: store.endpoint(for: provider))
        let temperature = useCustomTemperature ? min(temperature, 0.7) : nil
        let m = DiffSummaryPrompt.messages(for: spec)
        let cloud = summaryDetail == .brief ? 8_192 : 16_384
        let maxTokens = Self.outputBudget(answerTokens: cloud / 4, cloud: cloud, input: m, provider: provider)
        let label = "\(summaryDetail.title) summary · \(provider.model)"
        job = Task { [weak self] in
            do {
                guard let (text, cut) = try await self?.stream(client, Self.request(m, temperature: temperature, maxTokens: maxTokens), into: \.summary),
                      let self, !Task.isCancelled else { return }
                if cut { self.truncation = text.isEmpty ? .thinking : .answer }
                self.finish(label: label)
            } catch {
                guard let self else { return }
                if Task.isCancelled { self.finish(label: label); return }
                self.fail(error)
            }
        }
    }

    /// Local servers get room for long thinking; see `OutputBudget`.
    private static func outputBudget(answerTokens: Int, cloud: Int, input: RewritePrompt.Messages, provider: AIProvider) -> Int {
        OutputBudget.tokens(answerTokens: answerTokens, cloud: cloud, inputTokens: input.estimatedTokens,
                            contextLength: provider.contextLength, isLocal: provider.kind.isLocal)
    }

    private static func request(_ m: RewritePrompt.Messages, temperature: Double?, maxTokens: Int) -> LLMRequest {
        LLMRequest(context: m.context, system: m.system, messages: [LLMMessage(.user, m.user)], temperature: temperature, maxTokens: maxTokens)
    }

    /// Streams one request into `target`, keeping the "thinking" state current,
    /// and returns the cleaned final text. With `keepUntilText`, what `target`
    /// shows stays until the new answer starts (the second pass shouldn't
    /// blank the draft while the model thinks).
    private func stream(_ client: LLMClient, _ request: LLMRequest, into target: ReferenceWritableKeyPath<RewriteSession, String>, keepUntilText: Bool = false) async throws -> (text: String, truncated: Bool) {
        raw = ""
        reasoningCharacters = 0
        outputBudget = request.maxTokens
        var truncated = false
        var lastUpdate = Date.distantPast
        func publish() {
            let cleaned = RewritePrompt.clean(raw)
            if !(keepUntilText && cleaned.isEmpty) { self[keyPath: target] = cleaned }
            let inlineThinking = raw.contains("<think>") && !raw.contains("</think>")
            isThinking = cleaned.isEmpty && (reasoningCharacters > 0 || inlineThinking)
            lastUpdate = Date()
        }
        for try await delta in client.stream(request) {
            switch delta {
            case .text(let t): raw += t
            case .reasoning(let t): reasoningCharacters += t.count
            case .truncated: truncated = true
            }
            // Repainting on every token is wasteful; ~20 fps is plenty.
            if Date().timeIntervalSince(lastUpdate) > 0.05 { publish() }
        }
        publish()
        isThinking = false
        return (RewritePrompt.clean(raw), truncated)
    }

    func stop() {
        job?.cancel()
        job = nil
        if phase.isRunning { finish(label: nil) }
    }

    private func finish(label: String?) {
        phase = .finished
        job = nil
        isThinking = false
        if let startedAt { duration = Date().timeIntervalSince(startedAt) }
        if runTask == .rewrite { refreshTells() }
        let text = runTask == .summary ? summary : output
        if let label, let runTask, !text.isEmpty {
            history.insert(HistoryItem(task: runTask, text: text, label: label, date: Date(), passage: runTask == .rewrite ? outputPassage : nil), at: 0)
            if history.count > 20 { history.removeLast() }
        }
    }

    private func fail(_ error: Error) {
        phase = .failed(error.localizedDescription)
        job = nil
        isThinking = false
        if runTask == .rewrite { refreshTells() }
    }

    func refreshTells() {
        outputTells = output.isEmpty ? nil : AITells.scan(output)
    }

    func restore(_ item: HistoryItem) {
        guard !phase.isRunning else { return }
        task = item.task
        if item.task == .rewrite {
            output = item.text
            outputPassage = item.passage
            refreshTells()
        } else {
            summary = item.text
        }
        truncation = nil
        duration = nil
    }

    // MARK: Using the result

    /// Writes a whole-text result into one side.
    func apply(to side: DiffDocument.Side, in document: DiffDocument, compare: Bool) {
        guard !output.isEmpty, outputPassage == nil else { return }
        applyError = nil
        applied = Applied(side: side, previousText: document.text(for: side))
        document.setText(output, for: side)
        if compare, document.mode == .edit { document.mode = .split }
    }

    /// Puts a passage result back. In place replaces the selection in its own
    /// editor; otherwise the other side gets a copy of the document with the
    /// passage replaced, so the comparison shows exactly what changed.
    /// Returns false (and sets `applyError`) when the passage can't be found.
    @discardableResult
    func applyPassage(in document: DiffDocument, inPlace: Bool) -> Bool {
        guard let passage = outputPassage, !output.isEmpty else { return false }
        let current = document.text(for: passage.side)
        guard let range = SelectionRewrite.locate(passage.text, in: current, near: passage.range) else {
            applyError = "The selected passage changed after the rewrite, so it can’t be replaced. Select it again and rewrite."
            return false
        }
        applyError = nil
        let replacement = SelectionRewrite.fit(output, replacing: passage.text)
        if inPlace {
            applied = Applied(side: passage.side, previousText: current)
            document.replace(range, in: passage.side, with: replacement)
            // Rewriting again now targets the new text.
            let updated = Passage(side: passage.side, range: NSRange(location: range.location, length: (replacement as NSString).length), text: replacement)
            self.passage = updated
            outputPassage = updated
        } else {
            let other = passage.side.other
            guard let edited = SelectionRewrite.replacing(range, in: current, with: replacement) else { return false }
            applied = Applied(side: other, previousText: document.text(for: other))
            document.setText(edited, for: other)
            if document.mode == .edit { document.mode = .split }
        }
        return true
    }

    func revert(in document: DiffDocument) {
        guard let applied else { return }
        document.setText(applied.previousText, for: applied.side)
        self.applied = nil
    }

    #if DEBUG
    /// Tests: pretend the model returned `text` for the current target.
    func setResultForTesting(_ text: String) {
        output = text
        outputPassage = rewritesSelection ? passage : nil
        runTask = .rewrite
        phase = .finished
    }
    #endif
}
