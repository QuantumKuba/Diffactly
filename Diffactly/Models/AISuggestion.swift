import Foundation
import Combine
import DiffactlyCore

/// A proposed AI rewrite of one passage, waiting in the editor for the user
/// to accept or reject it. Nothing in the text changes until it's accepted.
///
/// The document keeps `range` pointing at the passage while the user edits
/// around it; the streaming answer and progress are published here so only
/// the suggestion's card redraws as tokens arrive.
///
/// Each answer the model gives becomes a version (V1, V2, …) instead of
/// replacing the last one. The answer fields below always describe the
/// version on show.
///
/// Parts of a version can be rewritten again on their own (refinements, see
/// below), each with versions of its own. What the card, Compare and Accept
/// use is the version on show with each part's chosen rewrite in place.
@MainActor
final class AISuggestion: ObservableObject, Identifiable {
    enum Status: Equatable {
        /// Waiting in its card for the user to pick settings and start it;
        /// nothing has been sent to the model yet.
        case configuring
        case drafting, auditing
        case ready
        case failed(String)
        /// The user edited the passage after asking, so the suggestion no
        /// longer replaces what's there.
        case stale

        var isRunning: Bool { self == .drafting || self == .auditing }
    }

    let id = UUID()
    /// The editor the passage is in (flips when the sides are swapped).
    var side: DiffDocument.Side
    /// Where the passage is now (UTF-16, kept current by the document). For
    /// a refinement: where its part is in the version it belongs to.
    var range: NSRange
    /// The passage as it was when the suggestion was requested.
    let original: String

    @Published var replacement = ""
    @Published var status: Status
    @Published var isThinking = false
    @Published var reasoningCharacters = 0
    @Published var truncation: RewriteTruncation?
    @Published var didAudit = false
    /// What produced it, e.g. "Humanize · Moderate · gpt-5".
    @Published var label = ""
    /// The blend that was used, e.g. "Based on the selection" (nil without a counterpart).
    @Published var basisLabel: String?
    @Published var startedAt = Date()
    @Published var duration: TimeInterval?

    /// The settings it was last asked with, to tell when they've changed
    /// since (nil when it came from the AI sheet).
    var settings: RewriteSession.SuggestionSettings?
    /// The request streaming into this suggestion.
    var job: Task<Void, Never>?
    /// The model finished its answer (so `replacement` is complete).
    var isComplete = false

    /// The finished answers, oldest first (V1, V2, …).
    @Published private(set) var versions: [Version] = []
    /// The version on show; nil while the answer being written (or one that
    /// failed) is on show, or for an answer set directly.
    @Published private(set) var shownVersionID: UUID?
    /// There's an answer being written, or one that failed, that isn't a version.
    @Published private(set) var hasAttempt = false
    /// That answer while an earlier version is on show.
    private var stashedAttempt: Answer?
    /// Identifies the request writing the attempt, so a cancelled one can't
    /// write into the next.
    private var attemptToken = UUID()

    static let versionLimit = 20

    /// For a refinement: the suggestion whose version it rewrites part of,
    /// and that version.
    private(set) weak var parent: AISuggestion?
    private(set) var parentVersionID: UUID?
    /// A refinement switched back to the wording of the version it's part of.
    @Published var usesParentWording = false
    /// The rewritten parts of each version, by version id, in text order.
    @Published private(set) var refinementsByVersion: [UUID: [AISuggestion]] = [:]
    /// Part of the version on show (in its text) the user picked in the
    /// editor to rewrite, waiting in the card for them to start it.
    @Published var proposedRefinement: NSRange?
    /// Repaints whatever shows this suggestion when one of its parts changes.
    private var refinementWatchers: [UUID: AnyCancellable] = [:]

    init(side: DiffDocument.Side, range: NSRange, original: String, status: Status = .drafting) {
        self.side = side
        self.range = range
        self.original = original
        self.status = status
    }

    var isReady: Bool { status == .ready && !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The text that goes into the editor: the answer, with its rewritten
    /// parts, wrapped in the passage's own leading and trailing whitespace.
    var fittedReplacement: String { SelectionRewrite.fit(composedReplacement, replacing: original) }

    /// Ready, and none of the rewritten parts on show is still being written.
    var isAcceptable: Bool { isReady && !refinements.contains { $0.status.isRunning && !$0.usesParentWording } }

    func cancel() {
        job?.cancel()
        job = nil
        // An answer cut off behind an earlier version can't finish now.
        if let stashed = stashedAttempt, stashed.status.isRunning {
            stashedAttempt = nil
            hasAttempt = false
        }
    }

    /// Stops this suggestion's request and those of all its rewritten parts.
    func cancelAll() {
        cancel()
        for parts in refinementsByVersion.values { for part in parts { part.cancelAll() } }
    }

    /// Word-level changes from the passage to the suggestion (with its
    /// rewritten parts), for the card.
    var changes: [DiffEngine.InlineChange] {
        DiffEngine.inlineChanges(original.trimmingCharacters(in: .whitespacesAndNewlines),
                                 composedReplacement.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Versions

extension AISuggestion {
    /// Everything the card shows about one answer.
    struct Answer: Equatable {
        var replacement = ""
        var status: Status = .drafting
        var isThinking = false
        var reasoningCharacters = 0
        var truncation: RewriteTruncation?
        var didAudit = false
        var label = ""
        var basisLabel: String?
        var startedAt = Date()
        var duration: TimeInterval?
        var isComplete = false
    }

    /// One finished answer.
    struct Version: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var label: String
        var basisLabel: String?
        var date: Date
        var duration: TimeInterval?
        var didAudit: Bool
        var truncation: RewriteTruncation?

        init(text: String, label: String, basisLabel: String? = nil, date: Date, duration: TimeInterval? = nil, didAudit: Bool = false, truncation: RewriteTruncation? = nil) {
            self.text = text
            self.label = label
            self.basisLabel = basisLabel
            self.date = date
            self.duration = duration
            self.didAudit = didAudit
            self.truncation = truncation
        }

        init(_ answer: Answer) {
            self.init(text: answer.replacement, label: answer.label, basisLabel: answer.basisLabel, date: answer.startedAt,
                      duration: answer.duration, didAudit: answer.didAudit, truncation: answer.truncation)
        }
    }

    /// The answer fields as one value; setting it only touches what changed.
    private var answer: Answer {
        get {
            Answer(replacement: replacement, status: status, isThinking: isThinking, reasoningCharacters: reasoningCharacters,
                   truncation: truncation, didAudit: didAudit, label: label, basisLabel: basisLabel,
                   startedAt: startedAt, duration: duration, isComplete: isComplete)
        }
        set {
            if replacement != newValue.replacement { replacement = newValue.replacement }
            if status != newValue.status { status = newValue.status }
            if isThinking != newValue.isThinking { isThinking = newValue.isThinking }
            if reasoningCharacters != newValue.reasoningCharacters { reasoningCharacters = newValue.reasoningCharacters }
            if truncation != newValue.truncation { truncation = newValue.truncation }
            if didAudit != newValue.didAudit { didAudit = newValue.didAudit }
            if label != newValue.label { label = newValue.label }
            if basisLabel != newValue.basisLabel { basisLabel = newValue.basisLabel }
            if startedAt != newValue.startedAt { startedAt = newValue.startedAt }
            if duration != newValue.duration { duration = newValue.duration }
            isComplete = newValue.isComplete
        }
    }

    /// How many versions there are to pick from, counting the answer being
    /// written (or that failed).
    var versionCount: Int { versions.count + (hasAttempt ? 1 : 0) }

    /// The number of the version on show (1 for V1); nil for an answer that
    /// isn't numbered.
    var shownVersionNumber: Int? {
        if let id = shownVersionID { return versions.firstIndex { $0.id == id }.map { $0 + 1 } }
        return hasAttempt ? versions.count + 1 : nil
    }

    /// Where the answer being written (or that failed) is at; nil without one.
    var attemptStatus: Status? { hasAttempt ? (stashedAttempt?.status ?? status) : nil }

    /// Stopping the answer being written would leave an earlier version to use.
    var canDiscardAttempt: Bool { hasAttempt && !versions.isEmpty }

    /// Starts a new answer, on show as the newest version while it streams.
    /// Returns the token its updates must carry.
    @discardableResult
    func beginAnswer(label: String, basisLabel: String?) -> UUID {
        // An answer set directly (from the AI panel, say) becomes V1.
        if shownVersionID == nil, !hasAttempt, isReady, isComplete { file(Version(answer)) }
        stashedAttempt = nil
        hasAttempt = true
        shownVersionID = nil
        proposedRefinement = nil
        attemptToken = UUID()
        answer = Answer(label: label, basisLabel: basisLabel)
        return attemptToken
    }

    /// Changes the answer being written, whether it's on show or behind an
    /// earlier version. Ignored for an answer that has been replaced.
    func updateAnswer(_ token: UUID, _ change: (inout Answer) -> Void) {
        guard hasAttempt, token == attemptToken else { return }
        if var stashed = stashedAttempt {
            let before = stashed.status
            change(&stashed)
            stashedAttempt = stashed
            if stashed.status != before { objectWillChange.send() }
        } else {
            var live = answer
            change(&live)
            answer = live
        }
    }

    /// Files the answer as the newest version once it's ready. One that failed
    /// or came back empty stays as the last attempt, next to the versions.
    func answerFinished(_ token: UUID) {
        guard hasAttempt, token == attemptToken else { return }
        let finished = stashedAttempt ?? answer
        guard finished.status == .ready, finished.isComplete,
              !finished.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let version = Version(finished)
        hasAttempt = false
        file(version)
        if stashedAttempt != nil {
            // The user is looking at an earlier version: leave it on show.
            stashedAttempt = nil
        } else {
            shownVersionID = version.id
        }
    }

    /// Shows a finished version, or with nil the answer being written (or
    /// that failed). Not while the suggestion is out of date.
    func showVersion(_ id: UUID?) {
        guard status != .stale, id != shownVersionID else { return }
        proposedRefinement = nil
        if let id {
            guard let version = versions.first(where: { $0.id == id }) else { return }
            if hasAttempt, stashedAttempt == nil { stashedAttempt = answer }
            shownVersionID = id
            answer = Answer(version)
        } else if let stashed = stashedAttempt {
            stashedAttempt = nil
            shownVersionID = nil
            answer = stashed
        }
    }

    /// Shows V`number` (the answer being written counts as the newest).
    func showVersion(number: Int) {
        if versions.indices.contains(number - 1) {
            showVersion(versions[number - 1].id)
        } else if number == versions.count + 1, hasAttempt {
            showVersion(nil)
        }
    }

    /// Stops the answer being written and goes back to the newest version.
    func discardAttempt() {
        job?.cancel()
        job = nil
        guard hasAttempt else { return }
        hasAttempt = false
        if stashedAttempt != nil {
            stashedAttempt = nil
        } else if let last = versions.last {
            shownVersionID = last.id
            answer = Answer(last)
        }
    }

    /// Takes over finished versions (the AI panel's for the same passage) and
    /// shows the one at `index`.
    func adoptVersions(_ list: [Version], showing index: Int) {
        guard list.indices.contains(index) else { return }
        cancelAll()
        refinementsByVersion = [:]
        refinementWatchers = [:]
        proposedRefinement = nil
        stashedAttempt = nil
        hasAttempt = false
        versions = list
        shownVersionID = list[index].id
        answer = Answer(list[index])
    }

    private func file(_ version: Version) {
        versions.append(version)
        // Drop the oldest, but never the one on show.
        while versions.count > Self.versionLimit, let i = versions.firstIndex(where: { $0.id != shownVersionID }) {
            let dropped = versions.remove(at: i)
            for part in refinementsByVersion.removeValue(forKey: dropped.id) ?? [] {
                part.cancelAll()
                refinementWatchers[part.id] = nil
            }
        }
    }
}

// MARK: - Refinements

/// A part of a version (a sentence or two, say) can be rewritten again on its
/// own, as a refinement: a suggestion of its own whose `range` is in the
/// version's text and whose versions are picked separately. Each version
/// keeps its own parts, so V2 of the paragraph with V1 of its first sentence
/// is one combination and V1 of the paragraph with its parts is another.
extension AISuggestion {
    /// One stretch of the combined text: the version's own wording, or a
    /// rewritten part.
    struct ComposedPart {
        var text: String
        /// The rewritten part this stretch shows (nil for the version's wording).
        var refinement: AISuggestion?
        /// Where the stretch is in the version's text.
        var versionRange: NSRange
    }

    var isRefinement: Bool { parent != nil }

    /// The rewritten parts of the version on show, in text order.
    var refinements: [AISuggestion] { shownVersionID.flatMap { refinementsByVersion[$0] } ?? [] }

    func refinementCount(forVersion id: UUID) -> Int { refinementsByVersion[id]?.count ?? 0 }

    /// What a rewritten part puts in its place: its answer on show (as far
    /// as it's written), or the version's own wording when switched back or
    /// when it failed.
    var chosenText: String {
        if usesParentWording || replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return original }
        switch status {
        case .failed, .stale, .configuring: return original
        case .drafting, .auditing, .ready: return SelectionRewrite.fit(replacement, replacing: original)
        }
    }

    /// The version on show split into its own wording and the rewritten parts.
    var composedParts: [ComposedPart] {
        let text = replacement as NSString
        var parts: [ComposedPart] = []
        var cursor = 0
        func plain(upTo end: Int) {
            guard end > cursor else { return }
            let range = NSRange(location: cursor, length: end - cursor)
            parts.append(ComposedPart(text: text.substring(with: range), refinement: nil, versionRange: range))
        }
        for part in refinements where part.range.location >= cursor && NSMaxRange(part.range) <= text.length {
            plain(upTo: part.range.location)
            parts.append(ComposedPart(text: part.chosenText, refinement: part, versionRange: part.range))
            cursor = NSMaxRange(part.range)
        }
        plain(upTo: text.length)
        return parts
    }

    /// The version on show with each rewritten part's chosen text in place.
    var composedReplacement: String {
        refinements.isEmpty ? replacement : composedParts.map(\.text).joined()
    }

    /// Where each of `parts` is in the combined text (UTF-16).
    static func composedRanges(_ parts: [ComposedPart]) -> [NSRange] {
        var location = 0
        return parts.map { part in
            let length = (part.text as NSString).length
            defer { location += length }
            return NSRange(location: location, length: length)
        }
    }

    /// Parts of the version on show can be rewritten: it's a finished answer
    /// and the passage hasn't been edited since.
    var canRefine: Bool {
        !isRefinement && status == .ready && isComplete && (shownVersionID != nil || !hasAttempt)
    }

    /// The part of the version on show behind `range` of the combined text,
    /// without surrounding whitespace. nil when it touches a rewritten part
    /// or there's nothing left.
    func versionRange(forComposed range: NSRange) -> NSRange? {
        let parts = composedParts
        let ranges = Self.composedRanges(parts)
        let composed = parts.map(\.text).joined() as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= composed.length else { return nil }
        let core = PassageAlignment.trimmed(range, in: composed)
        guard core.length > 0 else { return nil }
        for (part, at) in zip(parts, ranges) where part.refinement == nil {
            if core.location >= at.location, NSMaxRange(core) <= NSMaxRange(at) {
                return NSRange(location: part.versionRange.location + core.location - at.location, length: core.length)
            }
        }
        return nil
    }

    /// Where `range` of the version on show is in the combined text; nil
    /// when it overlaps a rewritten part.
    func composedRange(forVersion range: NSRange) -> NSRange? {
        let parts = composedParts
        for (part, at) in zip(parts, Self.composedRanges(parts)) where part.refinement == nil {
            if range.location >= part.versionRange.location, NSMaxRange(range) <= NSMaxRange(part.versionRange) {
                return NSRange(location: at.location + range.location - part.versionRange.location, length: range.length)
            }
        }
        return nil
    }

    /// Where `range` of the passage (relative to its start) went in the
    /// version on show, for a selection made in the editor. nil when it
    /// can't be told, or it lands on a part that's already rewritten.
    func versionRange(forPassage range: NSRange) -> NSRange? {
        guard canRefine, let mapped = PassageAlignment.map(range, from: original, to: replacement) else { return nil }
        return refinements.contains { NSIntersectionRange($0.range, mapped).length > 0 } ? nil : mapped
    }

    /// Adds `range` of the version on show (in its text) as a part to rewrite
    /// on its own; an answer set directly is filed as V1 first. nil when the
    /// range is blank, overlaps a part that's already rewritten, or the
    /// version can't be refined. Nothing is sent to the model here.
    @discardableResult
    func addRefinement(range: NSRange) -> AISuggestion? {
        guard canRefine else { return nil }
        let text = replacement as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length else { return nil }
        let core = PassageAlignment.trimmed(range, in: text)
        guard core.length > 0, !refinements.contains(where: { NSIntersectionRange($0.range, core).length > 0 }) else { return nil }
        if shownVersionID == nil {
            let version = Version(answer)
            file(version)
            shownVersionID = version.id
        }
        guard let versionID = shownVersionID else { return nil }
        let part = AISuggestion(side: side, range: core, original: text.substring(with: core))
        part.parent = self
        part.parentVersionID = versionID
        part.settings = settings
        var parts = refinementsByVersion[versionID] ?? []
        parts.append(part)
        parts.sort { $0.range.location < $1.range.location }
        refinementsByVersion[versionID] = parts
        refinementWatchers[part.id] = part.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        proposedRefinement = nil
        return part
    }

    /// Puts a saved rewritten part back on the version at `versionIndex`.
    func restoreRefinement(versionIndex: Int, range: NSRange, original: String, versions list: [Version],
                           showing index: Int?, usesParentWording: Bool) {
        guard versions.indices.contains(versionIndex), !list.isEmpty else { return }
        let version = versions[versionIndex]
        let text = version.text as NSString
        guard NSMaxRange(range) <= text.length, text.substring(with: range) == original,
              !(refinementsByVersion[version.id] ?? []).contains(where: { NSIntersectionRange($0.range, range).length > 0 })
        else { return }
        let part = AISuggestion(side: side, range: range, original: original, status: .ready)
        part.parent = self
        part.parentVersionID = version.id
        part.adoptVersions(list, showing: min(max(index ?? list.count - 1, 0), list.count - 1))
        part.usesParentWording = usesParentWording || index == nil
        var parts = refinementsByVersion[version.id] ?? []
        parts.append(part)
        parts.sort { $0.range.location < $1.range.location }
        refinementsByVersion[version.id] = parts
        refinementWatchers[part.id] = part.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Drops a rewritten part (its versions go with it).
    func removeRefinement(_ part: AISuggestion) {
        guard let versionID = part.parentVersionID else { return }
        part.cancelAll()
        refinementsByVersion[versionID]?.removeAll { $0 === part }
        if refinementsByVersion[versionID]?.isEmpty == true { refinementsByVersion[versionID] = nil }
        refinementWatchers[part.id] = nil
    }
}

extension AISuggestion.Answer {
    init(_ version: AISuggestion.Version) {
        self.init(replacement: version.text, status: .ready, truncation: version.truncation, didAudit: version.didAudit,
                  label: version.label, basisLabel: version.basisLabel, startedAt: version.date,
                  duration: version.duration, isComplete: true)
    }
}

/// How a suggestion's passage is painted in its editor.
struct SuggestionMark: Equatable {
    enum Style: Equatable {
        case pending, ready, stale
        /// An accepted rewrite reading as accepted, or as another of its
        /// steps (see RewriteHistory.swift). Opened by clicking, not hovering.
        case accepted, history

        var isHistory: Bool { self == .accepted || self == .history }
    }
    var id: UUID
    var range: NSRange
    var style: Style
}

/// Which suggestion's card is open, and whether the user opened it on purpose
/// (pinned) or it's only showing while the pointer rests on the passage.
struct SuggestionPresentation: Equatable {
    let requestID = UUID()
    var id: UUID
    var pinned: Bool
}
