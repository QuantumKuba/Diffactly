import Foundation
import DiffactlyCore

// Inline suggestions that open on their settings ("Humanize Selection with
// Options…", or always when the user prefers): the card shows the settings
// first and nothing goes to the model until the user starts it.

extension RewriteSession {
    /// The choices an inline suggestion is written with, to tell when they
    /// changed after it was asked for.
    struct SuggestionSettings: Equatable {
        var promptID: String
        var strength: RewriteStrength
        var includeOtherSide: Bool
        var passageWeight: Double
        var avoidAITells: Bool
        var academic: Bool
        var secondPass: SecondPassMode
        var extraNotes: String
        var providerID: UUID?
        var model: String
        var thinking: ThinkingEffort?
        /// Nil when sampling is left to the model.
        var temperature: Double?
    }

    func suggestionSettings(in store: AIStore, provider: AIProvider?) -> SuggestionSettings {
        SuggestionSettings(
            promptID: promptID,
            strength: strength,
            includeOtherSide: includeOtherSide,
            passageWeight: passageWeight,
            avoidAITells: avoidAITells,
            academic: appliesAcademic,
            secondPass: secondPass,
            extraNotes: extraNotes.trimmingCharacters(in: .whitespacesAndNewlines),
            providerID: provider?.id,
            model: provider?.model.trimmingCharacters(in: .whitespaces) ?? "",
            thinking: provider.map(\.thinking),
            temperature: useCustomTemperature ? temperature : nil
        )
    }

    /// The settings changed since `suggestion` was asked for (so regenerating
    /// would give a different answer).
    func settingsChanged(since suggestion: AISuggestion, store: AIStore) -> Bool {
        guard let used = suggestion.settings else { return false }
        return suggestionSettings(in: store, provider: resolvedProvider(in: store)) != used
    }

    // MARK: Showing options first

    static let optionsFirstKey = "rewrite.showOptionsFirst"

    /// The plain Humanize command opens the card on its settings too, so
    /// every suggestion can be set up before it's sent.
    static var showsOptionsFirst: Bool {
        get { UserDefaults.standard.bool(forKey: optionsFirstKey) }
        set { UserDefaults.standard.set(newValue, forKey: optionsFirstKey) }
    }

    /// Why a suggestion in setup can't be started yet (nil when it can).
    func suggestionBlocker(in store: AIStore) -> String? {
        guard let provider = resolvedProvider(in: store) else { return "Add an AI provider in Settings first." }
        if provider.model.trimmingCharacters(in: .whitespaces).isEmpty { return "Choose a model first." }
        return nil
    }

    /// Sends a suggestion that was waiting in setup to the model. If its
    /// passage was edited meanwhile, a new suggestion for the passage as it
    /// reads now takes its place.
    func startSuggestion(_ suggestion: AISuggestion, document: DiffDocument, store: AIStore) {
        guard suggestion.status == .configuring, document.suggestion(id: suggestion.id) === suggestion,
              suggestionBlocker(in: store) == nil, let provider = resolvedProvider(in: store) else { return }
        let ns = document.text(for: suggestion.side) as NSString
        guard NSMaxRange(suggestion.range) <= ns.length else { return }
        let current = ns.substring(with: suggestion.range)
        if current != suggestion.original {
            suggest(side: suggestion.side, range: suggestion.range, text: current, document: document, store: store)
            return
        }
        start(suggestion, provider: provider, document: document, store: store)
    }
}
