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

    /// What a result was made from. Results for the same subject are
    /// versions of one another (V1, V2, …).
    enum Subject: Hashable {
        /// A whole text, or both blended.
        case text(RewriteSource)
        /// A passage, by its side and its text when it was rewritten.
        case passage(DiffDocument.Side, String)
        case summary
    }

    /// One finished result: a version in its subject's series.
    struct HistoryItem: Identifiable, Equatable {
        var id = UUID()
        var task: AITask
        var text: String
        var label: String
        var date: Date
        /// Set when the result replaces a passage rather than a whole text.
        var passage: Passage?
        var sourceText: String = ""
        var subject: Subject = .summary
        var duration: TimeInterval?
        var didAudit = false
        var truncation: RewriteTruncation?
        var outputBudget = 0
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
    /// Apply the academic humanizer rules on top of the chosen prompt (so
    /// Humanize, Paraphrase, … keep a scholarly voice). See `appliesAcademic`.
    @Published var academicVoice: Bool { didSet { defaults.set(academicVoice, forKey: Keys.academic) } }
    @Published var secondPass: SecondPassMode { didSet { defaults.set(secondPass.rawValue, forKey: Keys.secondPassMode) } }
    @Published var preserveFormatting: Bool { didSet { defaults.set(preserveFormatting, forKey: Keys.formatting) } }
    @Published var useCustomTemperature: Bool { didSet { defaults.set(useCustomTemperature, forKey: Keys.useTemp) } }
    @Published var temperature: Double { didSet { defaults.set(temperature, forKey: Keys.temp) } }
    @Published var summaryDetail: SummaryDetail { didSet { defaults.set(summaryDetail.rawValue, forKey: Keys.summaryDetail) } }
    @Published var summaryFocus: SummaryFocus { didSet { defaults.set(summaryFocus.rawValue, forKey: Keys.summaryFocus) } }
    /// When rewriting a passage, also show the model the other side.
    @Published var includeOtherSide: Bool { didSet { defaults.set(includeOtherSide, forKey: Keys.includeOther) } }
    /// When rewriting a passage that has a counterpart on the other side, the
    /// share of the result that comes from the passage itself (1 = the other
    /// version is background only, 0.5 = even merge, 0 = follow the other).
    @Published var passageWeight: Double { didSet { defaults.set(passageWeight, forKey: Keys.passageWeight) } }
    /// One-off notes for this window; not persisted.
    @Published var extraNotes = ""

    /// Supplementary documents for this window's session.
    let references = ReferenceLibrary()

    // MARK: Results

    /// The selection captured when the sheet opened (nil when nothing was selected).
    @Published private(set) var passage: Passage? { didSet { if passage != oldValue { passageCounterpart = nil } } }
    /// The part of the other side that lines up with `passage`, found when the
    /// sheet opens and again before each run.
    @Published private(set) var passageCounterpart: PassageMatch.Match?
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
    typealias Truncation = RewriteTruncation

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
    @Published private(set) var outputVerification: AITells.Verification?
    /// Every result in this window, newest first; see `versions(for:)`.
    @Published private(set) var history: [HistoryItem] = []
    /// The subject of each task's result on show (or being written).
    @Published private(set) var resultSubject: [AITask: Subject] = [:]
    /// The version on show for each task; none while a result is being
    /// written, after a failure, or for one that wasn't kept.
    @Published private(set) var shownVersion: [AITask: UUID] = [:]
    /// A problem using the result (e.g. the passage changed in the meantime).
    @Published var applyError: String?

    private var lastSourceText = ""
    private var job: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    /// Versions kept per subject.
    static let versionLimit = 20

    private enum Keys {
        static let source = "rewrite.source"
        static let weight = "rewrite.leftWeight"
        static let strength = "rewrite.strength"
        static let prompt = "rewrite.prompt"
        static let provider = "rewrite.provider"
        static let avoid = "rewrite.avoidAITells"
        static let academic = "rewrite.academicVoice"
        static let secondPass = "rewrite.secondPass"           // legacy Bool
        static let secondPassMode = "rewrite.secondPassMode"
        static let formatting = "rewrite.preserveFormatting"
        static let useTemp = "rewrite.useCustomTemperature"
        static let temp = "rewrite.temperature"
        static let summaryDetail = "summary.detail"
        static let summaryFocus = "summary.focus"
        static let includeOther = "rewrite.includeOtherSide"
        static let passageWeight = "rewrite.passageWeight"
    }

    init() {
        let d = UserDefaults.standard
        source = RewriteSource(rawValue: d.string(forKey: Keys.source) ?? "") ?? .both
        leftWeight = d.object(forKey: Keys.weight) as? Double ?? 0.5
        strength = RewriteStrength(rawValue: d.string(forKey: Keys.strength) ?? "") ?? .moderate
        promptID = d.string(forKey: Keys.prompt) ?? RewritePreset.humanizeID
        providerID = d.string(forKey: Keys.provider).flatMap(UUID.init(uuidString:))
        avoidAITells = d.object(forKey: Keys.avoid) as? Bool ?? true
        academicVoice = d.bool(forKey: Keys.academic)
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
        passageWeight = d.object(forKey: Keys.passageWeight) as? Double ?? 1
    }

    /// The name of the prompt rewrites use, for menu titles ("Humanize Selection").
    static var currentPromptName: String {
        let id = UserDefaults.standard.string(forKey: Keys.prompt) ?? RewritePreset.humanizeID
        return (AIStore.shared.prompt(id: id) ?? RewritePreset.builtIns[0]).name
    }

    // MARK: Opening

    /// Called when the sheet appears: picks the tab and captures the selection.
    /// With text selected, a rewrite works on just that passage; rewriting a
    /// whole text has to be chosen in the sheet.
    func prepare(for document: DiffDocument) {
        task = document.aiTask
        if let selection = document.selection, !selection.text.isEmpty {
            let current = document.text(for: selection.side)
            let range = SelectionRewrite.locate(selection.text, in: current, near: selection.range) ?? selection.range
            passage = Passage(side: selection.side, range: range, text: selection.text)
        } else {
            passage = nil
        }
        if document.aiStartsWithSelection, passage != nil { task = .rewrite }
        rewritesSelection = passage != nil
        document.aiStartsWithSelection = false
        refreshCounterpart(document)
    }

    /// Finds the other side's matching part of the passage again.
    func refreshCounterpart(_ document: DiffDocument) {
        passageCounterpart = passage.flatMap { Self.counterpart(side: $0.side, range: $0.range, in: document) }
    }

    /// What the user highlighted on the other side when there is any;
    /// otherwise the part the comparison lines up with the passage.
    static func counterpart(side: DiffDocument.Side, range: NSRange, in document: DiffDocument) -> PassageMatch.Match? {
        let text = document.text(for: side) as NSString
        let passage = NSMaxRange(range) <= text.length ? text.substring(with: range) : ""
        if let marked = document.markedCounterpart(forPassageOn: side, passage: passage) { return marked }
        if let linked = document.linkedCounterpart(forPassageOn: side, range: range, passage: passage) { return linked }
        return PassageMatch.counterpart(in: document.currentResult(), fromLeft: side == .left, range: range,
                                        text: document.text(for: side), otherText: document.text(for: side.other))
    }

    /// Whether a passage rewrite reads `counterpart`: highlighted text always
    /// counts (the user picked it); a matched one only with “Use … as well” on.
    func usesCounterpart(_ counterpart: PassageMatch.Match?) -> Bool {
        guard let counterpart else { return false }
        return counterpart.isMarked || includeOtherSide
    }

    /// The blend can lean on the other version: it has a differing match.
    var canBlendPassage: Bool { usesCounterpart(passageCounterpart) && passageCounterpart.map { !$0.isIdentical } == true }

    /// "Based on the selection", "Even mix with Original", …
    static func basisDescription(weight: Double, otherTitle: String) -> String {
        switch weight {
        case 0.9...: return "Based on the selection"
        case 0.65..<0.9: return "Mostly the selection, some of \(otherTitle)"
        case 0.35..<0.65: return "Even mix with \(otherTitle)"
        case 0.1..<0.35: return "Mostly \(otherTitle), some of the selection"
        default: return "Based on \(otherTitle)"
        }
    }

    /// The card's blend line, e.g. "Even mix with Original · your highlights".
    static func basisLabel(_ spec: SelectionRewriteSpec, weight: Double, otherTitle: String) -> String? {
        var parts: [String] = []
        if spec.usableCounterpart != nil {
            parts.append(basisDescription(weight: weight, otherTitle: otherTitle) + (spec.counterpartIsMarked ? " (highlighted)" : ""))
        }
        let excerpts = spec.usableExcerpts.count
        if excerpts > 0 { parts.append("\(excerpts) highlighted excerpt\(excerpts == 1 ? "" : "s")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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

    /// The Academic Humanize prompt always uses the academic rules; any other
    /// prompt uses them when the option is on.
    var promptIsAcademic: Bool { promptID == RewritePreset.academicID }
    var appliesAcademic: Bool { academicVoice || promptIsAcademic }

    /// "Paraphrase + Academic": the prompt, with the academic option when it's layered on.
    func styleName(in store: AIStore) -> String {
        let name = resolvedPrompt(in: store).name
        return appliesAcademic && !promptIsAcademic ? name + " + Academic" : name
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
            markup: markup(document, sides: sides),
            academic: appliesAcademic
        )
    }

    /// - Parameter counterpart: the other side's matching part of the passage
    ///   (only used while `includeOtherSide` is on).
    func selectionSpec(_ passage: Passage, document: DiffDocument, store: AIStore, counterpart: PassageMatch.Match? = nil, withReferences: Bool = true) -> SelectionRewriteSpec {
        let side = passage.side
        let match = usesCounterpart(counterpart) ? counterpart : nil
        return SelectionRewriteSpec(
            documentText: document.text(for: side),
            documentTitle: document.title(for: side),
            fileName: side == .left ? document.leftName : document.rightName,
            range: passage.range,
            otherText: includeOtherSide ? document.text(for: side.other) : nil,
            otherTitle: document.title(for: side.other),
            counterpart: match.flatMap { $0.isIdentical ? nil : $0.text },
            counterpartIsMarked: match?.isMarked == true,
            markedExcerpts: document.markedExcerpts(on: side, excluding: passage.range),
            passageWeight: passageWeight,
            strength: strength,
            instructions: resolvedPrompt(in: store).instructions,
            extraNotes: [extraNotes, Self.commentNotes(on: passage, in: document)]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n"),
            avoidAITells: avoidAITells,
            references: withReferences ? referenceDocuments(for: document) : [],
            markup: markup(document, sides: [side]),
            academic: appliesAcademic
        )
    }

    /// The open comments on a passage, as instructions for the model (the
    /// user's notes on that text, e.g. “too formal here”).
    static func commentNotes(on passage: Passage, in document: DiffDocument) -> String {
        let notes = document.comments
            .filter { $0.side == passage.side && !$0.isDetached && !$0.isResolved && !$0.isBlank
                && NSIntersectionRange($0.range, passage.range).length > 0 }
            .sorted { $0.range.location < $1.range.location }
            .map { "- On “\($0.snippet)”: \($0.body.trimmingCharacters(in: .whitespacesAndNewlines))" }
        guard !notes.isEmpty else { return "" }
        return "The user left these comments on the passage. Address each one in the rewrite:\n" + notes.joined(separator: "\n")
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
            if rewritesSelection, let passage { return SelectionRewrite.messages(for: selectionSpec(passage, document: document, store: store, counterpart: passageCounterpart)) }
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
                return SelectionRewrite.messages(for: selectionSpec(passage, document: document, store: store, counterpart: passageCounterpart, withReferences: false)).estimatedTokens + references
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
        keepEdits()
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

    private func begin(_ task: AITask, phase: Phase, subject: Subject) {
        resultSubject[task] = subject
        shownVersion[task] = nil
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
        let sourceText = (spec.source != .right ? spec.leftText : "") + (spec.source != .left ? "\n\n" + spec.rightText : "")
        let markup = spec.markup ?? TextMarkup.detect(sourceText)
        let messages = RewritePrompt.messages(for: spec)
        // Room for the answer (≈ 2× the source) plus a reasoning model's thinking.
        let maxTokens = RewriteRunner.outputBudget(
            answerTokens: sourceText.count / 4,
            cloud: min(32_000, max(8_192, sourceText.count / 2 + 4_096)),
            input: messages, provider: provider)
        startRewrite(
            first: messages,
            audit: { draft, flagged, missingNumbers in
                RewritePrompt.auditMessages(draft: draft, spec: spec, flagged: flagged, missingNumbers: missingNumbers)
            },
            sourceUsesDashes: markup.usesEmDashes(sourceText),
            sourceText: sourceText,
            maxTokens: maxTokens,
            passage: nil,
            label: "\(styleName(in: store)) · \(strength.title) · \(provider.model)",
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
        refreshCounterpart(document)
        let spec = selectionSpec(passage, document: document, store: store, counterpart: passageCounterpart)
        let markup = spec.markup ?? TextMarkup.detect(spec.documentText, fileName: spec.fileName)
        let messages = SelectionRewrite.messages(for: spec)
        startRewrite(
            first: messages,
            audit: { draft, flagged, missingNumbers in
                SelectionRewrite.auditMessages(draft: draft, spec: spec, flagged: flagged, missingNumbers: missingNumbers)
            },
            sourceUsesDashes: markup.usesEmDashes(passage.text),
            sourceText: passage.text,
            maxTokens: RewriteRunner.passageBudget(passage.text, input: messages, provider: provider),
            passage: passage,
            label: "\(styleName(in: store)) · \(strength.title) (selection) · \(provider.model)",
            client: LLMClient(endpoint: store.endpoint(for: provider))
        )
    }

    /// Shared by whole-text and passage rewrites: a draft, then optionally a
    /// checking pass.
    private func startRewrite(
        first: RewritePrompt.Messages,
        audit: @escaping (String, [String], [String]) -> RewritePrompt.Messages,
        sourceUsesDashes: Bool,
        sourceText: String,
        maxTokens: Int,
        passage: Passage?,
        label: String,
        client: LLMClient
    ) {
        let run = RewriteRunner.Job(
            client: client, first: first, audit: audit, secondPass: secondPass, checkTells: avoidAITells,
            academic: appliesAcademic,
            sourceUsesDashes: sourceUsesDashes, sourceText: sourceText, strength: strength,
            temperature: useCustomTemperature ? temperature : nil, maxTokens: maxTokens)
        lastSourceText = sourceText
        output = ""
        outputPassage = passage
        outputTells = nil
        outputVerification = nil
        didAudit = false
        begin(.rewrite, phase: .drafting, subject: subject(passage: passage))
        job = Task { [weak self] in
            do {
                let outcome = try await RewriteRunner.run(run) { [weak self] update in self?.apply(update) }
                guard let self, !Task.isCancelled else { return }
                self.output = outcome.text
                self.truncation = outcome.truncation
                self.finish(label: label)
            } catch {
                guard let self else { return }
                if Task.isCancelled || error is CancellationError { self.finish(label: label + " · Stopped"); return }
                self.fail(error)
            }
        }
    }

    /// Mirrors a rewrite's progress in the sheet.
    private func apply(_ update: RewriteRunner.Update) {
        switch update {
        case .stage(let stage):
            phase = stage == .drafting ? .drafting : .auditing
            if stage == .auditing { didAudit = true }
        case .text(let text): output = text
        case .thinking(let thinking, let characters):
            isThinking = thinking
            reasoningCharacters = characters
        case .budget(let tokens): outputBudget = tokens
        }
    }

    private func runSummary(provider: AIProvider, document: DiffDocument, store: AIStore) {
        let spec = summarySpec(document: document)
        summary = ""
        begin(.summary, phase: .summarizing, subject: .summary)
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
        let maxTokens = RewriteRunner.outputBudget(answerTokens: cloud / 4, cloud: cloud, input: m, provider: provider)
        let label = "\(summaryDetail.title) summary · \(provider.model)"
        job = Task { [weak self] in
            do {
                let request = RewriteRunner.request(m, temperature: temperature, maxTokens: maxTokens)
                let (text, cut) = try await RewriteRunner.stream(client, request) { [weak self] update in
                    guard let self else { return }
                    switch update {
                    case .text(let text): self.summary = text
                    case .thinking(let thinking, let characters):
                        self.isThinking = thinking
                        self.reasoningCharacters = characters
                    case .budget(let tokens): self.outputBudget = tokens
                    case .stage: break
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.summary = text
                if cut { self.truncation = text.isEmpty ? .thinking : .answer }
                self.finish(label: label)
            } catch {
                guard let self else { return }
                if Task.isCancelled || error is CancellationError { self.finish(label: label + " · Stopped"); return }
                self.fail(error)
            }
        }
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
            let isRewrite = runTask == .rewrite
            record(HistoryItem(
                task: runTask, text: text, label: label, date: Date(),
                passage: isRewrite ? outputPassage : nil, sourceText: lastSourceText,
                subject: resultSubject[runTask] ?? (isRewrite ? subject(passage: outputPassage) : .summary),
                duration: duration, didAudit: isRewrite && didAudit, truncation: truncation, outputBudget: outputBudget))
        }
    }

    /// Adds a result as the newest version of its subject and shows it.
    private func record(_ item: HistoryItem) {
        history.insert(item, at: 0)
        resultSubject[item.task] = item.subject
        shownVersion[item.task] = item.id
        let series = history.filter { $0.subject == item.subject }
        if series.count > Self.versionLimit, let oldest = series.last {
            history.removeAll { $0.id == oldest.id }
        }
        // A bound for the whole window, oldest first.
        if history.count > Self.versionLimit * 5 { history.removeLast(history.count - Self.versionLimit * 5) }
    }

    private func subject(passage: Passage?) -> Subject {
        passage.map { .passage($0.side, $0.text) } ?? .text(source)
    }

    /// The versions of `task`'s result on show, oldest first (V1, V2, …).
    func versions(for task: AITask) -> [HistoryItem] {
        guard let subject = resultSubject[task] else { return [] }
        return history.filter { $0.subject == subject }.reversed()
    }

    /// Which of `versions(for:)` is on show (1 for V1).
    func shownVersionNumber(for task: AITask) -> Int? {
        guard let id = shownVersion[task] else { return nil }
        return versions(for: task).firstIndex { $0.id == id }.map { $0 + 1 }
    }

    /// The newest version of every other subject `task` has results for,
    /// newest first, with how many versions each has.
    func otherResults(for task: AITask) -> [(item: HistoryItem, count: Int)] {
        var seen: Set<Subject> = resultSubject[task].map { [$0] } ?? []
        var results: [(item: HistoryItem, count: Int)] = []
        for item in history where item.task == task && seen.insert(item.subject).inserted {
            results.append((item, history.filter { $0.subject == item.subject }.count))
        }
        return results
    }

    /// Keeps edits made in the output with the version they were made to.
    private func keepEdits() {
        guard !phase.isRunning, !output.isEmpty, let id = shownVersion[.rewrite],
              let index = history.firstIndex(where: { $0.id == id }), history[index].text != output else { return }
        history[index].text = output
    }

    private func fail(_ error: Error) {
        phase = .failed(error.localizedDescription)
        job = nil
        isThinking = false
        if runTask == .rewrite { refreshTells() }
    }

    func refreshTells() {
        outputTells = output.isEmpty ? nil : AITells.scan(output)
        outputVerification = (output.isEmpty || lastSourceText.isEmpty)
            ? nil
            : AITells.verify(source: lastSourceText, result: output)
    }

    /// Puts a version back on show: the output (or summary) shows it, and
    /// Copy, Use Result and Review in Text work on it.
    func restore(_ item: HistoryItem) {
        guard !phase.isRunning else { return }
        keepEdits()
        task = item.task
        if item.task == .rewrite {
            output = item.text
            outputPassage = item.passage
            lastSourceText = item.sourceText
            didAudit = item.didAudit
            refreshTells()
        } else {
            summary = item.text
        }
        resultSubject[item.task] = item.subject
        shownVersion[item.task] = item.id
        runTask = item.task
        phase = .finished
        truncation = item.truncation
        outputBudget = item.outputBudget
        duration = item.duration
    }

    // MARK: Using the result

    /// Writes a whole-text result into one side.
    func apply(to side: DiffDocument.Side, in document: DiffDocument, compare: Bool) {
        guard !output.isEmpty, outputPassage == nil else { return }
        applyError = nil
        let previous = document.text(for: side)
        applied = Applied(side: side, previousText: previous)
        let earlier = document.takeRewrites(inside: NSRange(location: 0, length: (previous as NSString).length), on: side)
        document.setText(output, for: side)
        // The whole text keeps what it said before, like an accepted suggestion.
        document.recordRewrite(side: side, range: NSRange(location: 0, length: (output as NSString).length),
                               original: previous, rewrite: output, label: appliedLabel, earlier: earlier)
        if compare, document.mode == .edit { document.mode = .split }
    }

    /// What produced the result being applied, for its history.
    private var appliedLabel: String {
        history.first(where: { $0.task == task })?.label ?? ""
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
            let counterpart = Self.counterpart(side: passage.side, range: range, in: document)
            let earlier = document.takeRewrites(inside: range, on: passage.side)
            document.replace(range, in: passage.side, with: replacement)
            let inserted = NSRange(location: range.location, length: (replacement as NSString).length)
            document.recordRewrite(side: passage.side, range: inserted, original: passage.text, rewrite: replacement,
                                   label: appliedLabel, earlier: earlier)
            document.linkAcceptedRewrite(side: passage.side, range: inserted, counterpart: counterpart)
            // Rewriting again now targets the new text.
            let updated = Passage(side: passage.side, range: inserted, text: replacement)
            self.passage = updated
            outputPassage = updated
        } else {
            let other = passage.side.other
            guard let edited = SelectionRewrite.replacing(range, in: current, with: replacement) else { return false }
            applied = Applied(side: other, previousText: document.text(for: other))
            document.setText(edited, for: other)
            // The copy's passage keeps what it said before (still on its own side).
            document.recordRewrite(side: other, range: NSRange(location: range.location, length: (replacement as NSString).length),
                                   original: passage.text, rewrite: replacement, label: appliedLabel)
            if document.mode == .edit { document.mode = .split }
        }
        return true
    }

    func revert(in document: DiffDocument) {
        guard let applied else { return }
        document.setText(applied.previousText, for: applied.side)
        self.applied = nil
    }

    // MARK: Inline suggestions

    /// Starts an inline suggestion for a passage with the current settings.
    /// Its card opens at once and the answer streams into it; the text only
    /// changes when the user accepts it. With `showingOptions` the card opens
    /// on its settings instead and nothing is sent until the user starts it.
    ///
    /// A selection inside a passage that already has a finished suggestion
    /// doesn't replace it: the whole passage asks for another version, and
    /// part of it is carried over to the suggestion's text and offered in
    /// its card as a part to rewrite on its own.
    func suggest(side: DiffDocument.Side, range: NSRange, text: String, document: DiffDocument, store: AIStore, showingOptions: Bool = false) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let existing = document.suggestion(enclosing: range, on: side), existing.canRefine {
            let ns = existing.original as NSString
            let local = NSRange(location: range.location - existing.range.location, length: range.length)
            let passage = PassageAlignment.trimmed(NSRange(location: 0, length: ns.length), in: ns)
            let picked = PassageAlignment.trimmed(local, in: ns)
            if picked == passage {
                if !showingOptions { regenerate(existing, document: document, store: store) }
                document.presentSuggestion(existing.id, pinned: true)
                return
            }
            // When it can't be carried over (it lands on a part that's already
            // rewritten, say), the card opens for picking the words there.
            existing.proposedRefinement = existing.versionRange(forPassage: local)
            document.presentSuggestion(existing.id, pinned: true)
            return
        }
        if showingOptions {
            document.addSuggestion(AISuggestion(side: side, range: range, original: text, status: .configuring))
            return
        }
        guard let provider = resolvedProvider(in: store), !provider.model.trimmingCharacters(in: .whitespaces).isEmpty else {
            // No model yet: the sheet explains how to connect one.
            document.showAI(.rewrite, selection: true)
            return
        }
        let suggestion = AISuggestion(side: side, range: range, original: text)
        document.addSuggestion(suggestion)
        start(suggestion, provider: provider, document: document, store: store)
    }

    /// What the window's document calls to suggest a rewrite (⌥⌘E, menus;
    /// with options, ⌥⇧⌘E), without either keeping the other alive.
    func suggestionHandler(for document: DiffDocument) -> (DiffDocument.Side, NSRange, String, Bool) -> Void {
        { [weak self, weak document] side, range, text, withOptions in
            guard let self, let document else { return }
            self.suggest(side: side, range: range, text: text, document: document, store: .shared,
                         showingOptions: withOptions || Self.showsOptionsFirst)
        }
    }

    /// Rewrites `range` of the version on show (in its text) on its own, as a
    /// part of the suggestion with versions of its own.
    func refine(_ suggestion: AISuggestion, range: NSRange, document: DiffDocument, store: AIStore) {
        guard let provider = resolvedProvider(in: store), !provider.model.trimmingCharacters(in: .whitespaces).isEmpty else {
            document.showAI(.rewrite, selection: true)
            return
        }
        guard let part = suggestion.addRefinement(range: range) else { return }
        start(part, provider: provider, document: document, store: store)
    }

    /// Asks again with the current settings. A stale suggestion is replaced
    /// by a new one for the passage as it reads now.
    func regenerate(_ suggestion: AISuggestion, document: DiffDocument, store: AIStore) {
        if suggestion.status == .stale {
            let ns = document.text(for: suggestion.side) as NSString
            guard NSMaxRange(suggestion.range) <= ns.length else { return }
            suggest(side: suggestion.side, range: suggestion.range, text: ns.substring(with: suggestion.range), document: document, store: store)
            return
        }
        guard let provider = resolvedProvider(in: store), !provider.model.trimmingCharacters(in: .whitespaces).isEmpty else {
            document.showAI(.rewrite, selection: true)
            return
        }
        suggestion.cancel()
        start(suggestion, provider: provider, document: document, store: store)
    }

    func start(_ suggestion: AISuggestion, provider: AIProvider, document: DiffDocument, store: AIStore) {
        suggestion.settings = suggestionSettings(in: store, provider: provider)
        references.refresh()
        let side = suggestion.side
        let spec: SelectionRewriteSpec
        if let parent = suggestion.parent {
            guard let refined = refinementSpec(suggestion, of: parent, document: document, store: store) else {
                suggestion.status = .failed("The suggestion this part belongs to has changed, so it can’t be rewritten.")
                return
            }
            spec = refined
        } else {
            let passage = Passage(side: side, range: suggestion.range, text: suggestion.original)
            let counterpart = Self.counterpart(side: side, range: passage.range, in: document)
            spec = selectionSpec(passage, document: document, store: store, counterpart: counterpart)
        }
        let passage = Passage(side: side, range: spec.range, text: suggestion.original)
        let markup = spec.markup ?? TextMarkup.detect(spec.documentText, fileName: spec.fileName)
        let messages = SelectionRewrite.messages(for: spec)
        let run = RewriteRunner.Job(
            client: LLMClient(endpoint: store.endpoint(for: provider)),
            first: messages,
            audit: { draft, flagged, missingNumbers in
                SelectionRewrite.auditMessages(draft: draft, spec: spec, flagged: flagged, missingNumbers: missingNumbers)
            },
            secondPass: secondPass, checkTells: avoidAITells,
            academic: appliesAcademic,
            sourceUsesDashes: markup.usesEmDashes(passage.text),
            sourceText: passage.text,
            strength: strength,
            temperature: useCustomTemperature ? temperature : nil,
            maxTokens: RewriteRunner.passageBudget(passage.text, input: messages, provider: provider))

        // A new version: earlier answers stay available in the card.
        let answer = suggestion.beginAnswer(
            label: "\(styleName(in: store)) · \(strength.title) · \(provider.model)",
            basisLabel: Self.basisLabel(spec, weight: passageWeight, otherTitle: document.title(for: side.other)))
        // Back on the newest answer, so the new one shows in the text.
        suggestion.usesParentWording = false
        document.suggestionStatusChanged()

        suggestion.job = Task { [weak suggestion, weak document] in
            do {
                let outcome = try await RewriteRunner.run(run) { update in
                    suggestion?.updateAnswer(answer) { a in
                        switch update {
                        case .stage(let stage):
                            // An edit to the passage (stale) wins over progress.
                            if a.status.isRunning { a.status = stage == .drafting ? .drafting : .auditing }
                            if stage == .auditing { a.didAudit = true }
                        case .text(let text): a.replacement = text
                        case .thinking(let thinking, let characters):
                            a.isThinking = thinking
                            a.reasoningCharacters = characters
                        case .budget: break
                        }
                    }
                }
                guard let suggestion, !Task.isCancelled else { return }
                suggestion.updateAnswer(answer) { a in
                    a.replacement = outcome.text
                    a.truncation = outcome.truncation
                    a.isComplete = true
                    a.duration = Date().timeIntervalSince(a.startedAt)
                    if a.status.isRunning {
                        if !outcome.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            a.status = .ready
                        } else if outcome.truncation == .thinking {
                            a.status = .failed("The model spent its whole output budget thinking and never answered. Lower Thinking in the settings, or give a local model a bigger context window.")
                        } else {
                            a.status = .failed("The model returned no text.")
                        }
                    }
                }
                suggestion.answerFinished(answer)
                document?.suggestionStatusChanged()
            } catch {
                guard let suggestion, !Task.isCancelled, !(error is CancellationError) else { return }
                suggestion.updateAnswer(answer) { a in
                    a.isThinking = false
                    if a.status.isRunning { a.status = .failed(error.localizedDescription) }
                }
                document?.suggestionStatusChanged()
            }
        }
    }

    /// The request for a rewritten part: the side's text reads as if the
    /// suggestion were accepted (with its other parts as chosen), and the
    /// part is the selection. The other side isn't blended in: what lines up
    /// with the passage there is for the whole passage, not this part.
    func refinementSpec(_ part: AISuggestion, of parent: AISuggestion, document: DiffDocument, store: AIStore) -> SelectionRewriteSpec? {
        let parts = parent.composedParts
        guard let index = parts.firstIndex(where: { $0.refinement === part }) else { return nil }
        let before = parts[..<index].map(\.text).joined()
        let after = parts[(index + 1)...].map(\.text).joined()
        let combined = before + part.original + after
        let fitted = SelectionRewrite.fit(combined, replacing: parent.original)
        guard let documentText = SelectionRewrite.replacing(parent.range, in: document.text(for: parent.side), with: fitted) else { return nil }
        // `fit` swaps the combined text's own outer whitespace for the passage's.
        let leadingInPassage = (String(parent.original.prefix { $0.isWhitespace }) as NSString).length
        let leadingInCombined = (String(combined.prefix { $0.isWhitespace }) as NSString).length
        let location = parent.range.location + leadingInPassage + (before as NSString).length - leadingInCombined
        var spec = selectionSpec(Passage(side: parent.side, range: parent.range, text: parent.original),
                                 document: document, store: store, counterpart: nil)
        spec.documentText = documentText
        spec.range = NSRange(location: location, length: (part.original as NSString).length)
        spec.counterpart = nil
        spec.counterpartIsMarked = false
        return spec
    }

    /// Turns the sheet's passage result into an inline suggestion, so it can
    /// be reviewed (and accepted or rejected) where it goes.
    @discardableResult
    func reviewPassageInText(document: DiffDocument) -> Bool {
        guard let passage = outputPassage, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let range = SelectionRewrite.locate(passage.text, in: document.text(for: passage.side), near: passage.range) else {
            applyError = "The selected passage changed after the rewrite, so it can’t be reviewed in place. Select it again and rewrite."
            return false
        }
        applyError = nil
        keepEdits()
        let suggestion = AISuggestion(side: passage.side, range: range, original: passage.text, status: .ready)
        let series = versions(for: .rewrite)
        if let id = shownVersion[.rewrite], let index = series.firstIndex(where: { $0.id == id }) {
            // The passage's versions come along, so the card can switch between them.
            suggestion.adoptVersions(series.map {
                AISuggestion.Version(text: $0.text, label: $0.label, date: $0.date, duration: $0.duration,
                                     didAudit: $0.didAudit, truncation: $0.truncation)
            }, showing: index)
        } else {
            suggestion.replacement = output
            suggestion.isComplete = true
            suggestion.didAudit = didAudit
            suggestion.label = history.first(where: { $0.task == .rewrite })?.label ?? ""
            suggestion.duration = duration
        }
        document.addSuggestion(suggestion)
        return true
    }

    // MARK: Saved sessions

    /// Results, references or notes worth keeping in this window.
    var hasWork: Bool {
        !history.isEmpty || !references.attachedItems.isEmpty || !extraNotes.isEmpty
    }

    /// The choices and every result, for a saved session. Edits made to the
    /// output on show go with its version (as they would on the next run).
    func sessionState() -> SessionManifest.AIState {
        var items = history
        if !phase.isRunning, !output.isEmpty, let id = shownVersion[.rewrite],
           let index = items.firstIndex(where: { $0.id == id }) {
            items[index].text = output
        }
        return SessionManifest.AIState(
            task: task, source: source, leftWeight: leftWeight, strength: strength, promptID: promptID,
            providerID: providerID, avoidAITells: avoidAITells, academicVoice: academicVoice, secondPass: secondPass,
            preserveFormatting: preserveFormatting, useCustomTemperature: useCustomTemperature, temperature: temperature,
            summaryDetail: summaryDetail, summaryFocus: summaryFocus, includeOtherSide: includeOtherSide,
            passageWeight: passageWeight, extraNotes: extraNotes,
            history: items.map(Self.state),
            shownRewrite: shownVersion[.rewrite], shownSummary: shownVersion[.summary])
    }

    /// Puts back a saved session's choices and results, showing the versions
    /// that were on show.
    func restore(_ state: SessionManifest.AIState) {
        stop()
        source = state.source
        leftWeight = state.leftWeight
        strength = state.strength
        promptID = state.promptID
        providerID = state.providerID
        avoidAITells = state.avoidAITells
        academicVoice = state.academicVoice
        secondPass = state.secondPass
        preserveFormatting = state.preserveFormatting
        useCustomTemperature = state.useCustomTemperature
        temperature = state.temperature
        summaryDetail = state.summaryDetail
        summaryFocus = state.summaryFocus
        includeOtherSide = state.includeOtherSide
        passageWeight = state.passageWeight
        extraNotes = state.extraNotes
        history = state.history.map(Self.item)
        resultSubject = [:]
        shownVersion = [:]
        output = ""
        outputPassage = nil
        summary = ""
        applied = nil
        phase = .idle
        for id in [state.shownSummary, state.shownRewrite].compactMap({ $0 }) {
            if let item = history.first(where: { $0.id == id }) { restore(item) }
        }
        task = state.task
    }

    private static func state(_ item: HistoryItem) -> SessionManifest.ResultState {
        let subject: SessionManifest.SubjectState
        switch item.subject {
        case .text(let source): subject = .init(kind: .text, source: source)
        case .passage(let side, let text): subject = .init(kind: .passage, side: side, text: text)
        case .summary: subject = .init(kind: .summary)
        }
        return SessionManifest.ResultState(
            id: item.id, task: item.task, text: item.text, label: item.label, date: item.date,
            passage: item.passage.map { .init(side: $0.side, location: $0.range.location, length: $0.range.length, text: $0.text) },
            sourceText: item.sourceText, subject: subject, duration: item.duration, didAudit: item.didAudit,
            truncation: item.truncation, outputBudget: item.outputBudget)
    }

    private static func item(_ state: SessionManifest.ResultState) -> HistoryItem {
        let subject: Subject
        switch state.subject.kind {
        case .text: subject = .text(state.subject.source ?? .both)
        case .passage: subject = .passage(state.subject.side ?? .left, state.subject.text ?? "")
        case .summary: subject = .summary
        }
        return HistoryItem(
            id: state.id, task: state.task, text: state.text, label: state.label, date: state.date,
            passage: state.passage.map { Passage(side: $0.side, range: NSRange(location: $0.location, length: $0.length), text: $0.text) },
            sourceText: state.sourceText, subject: subject, duration: state.duration, didAudit: state.didAudit,
            truncation: state.truncation, outputBudget: state.outputBudget)
    }

    #if DEBUG
    /// Tests: pretend the model returned `text` for the current target.
    func setResultForTesting(_ text: String, label: String = "Test") {
        keepEdits()
        output = text
        outputPassage = rewritesSelection ? passage : nil
        if let p = outputPassage { lastSourceText = p.text }
        resultSubject[.rewrite] = subject(passage: outputPassage)
        runTask = .rewrite
        finish(label: label)
    }

    /// Tests: pretend the model returned `text` as a difference summary.
    func setSummaryForTesting(_ text: String, label: String = "Test") {
        summary = text
        resultSubject[.summary] = .summary
        runTask = .summary
        finish(label: label)
    }
    #endif
}
