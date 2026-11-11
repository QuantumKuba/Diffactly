import Foundation

/// Rewriting one selected passage while the model sees the whole document.
public struct SelectionRewriteSpec: Sendable {
    /// The full text of the side the selection is in.
    public var documentText: String
    public var documentTitle: String
    /// File name of that side, if it came from a file (helps detect LaTeX).
    public var fileName: String?
    /// UTF-16 range of the passage (NSTextView / NSString coordinates).
    public var range: NSRange
    /// The other side of the comparison, offered as background when set.
    public var otherText: String?
    public var otherTitle: String
    public var strength: RewriteStrength
    public var instructions: String
    public var extraNotes: String
    public var avoidAITells: Bool
    public var references: [ReferenceDocument]
    /// nil detects the markup from the document.
    public var markup: TextMarkup?

    public init(
        documentText: String, documentTitle: String = "Changed", fileName: String? = nil,
        range: NSRange, otherText: String? = nil, otherTitle: String = "Original",
        strength: RewriteStrength = .moderate, instructions: String, extraNotes: String = "",
        avoidAITells: Bool = true, references: [ReferenceDocument] = [], markup: TextMarkup? = nil
    ) {
        self.documentText = documentText
        self.documentTitle = documentTitle
        self.fileName = fileName
        self.range = range
        self.otherText = otherText
        self.otherTitle = otherTitle
        self.strength = strength
        self.instructions = instructions
        self.extraNotes = extraNotes
        self.avoidAITells = avoidAITells
        self.references = references
        self.markup = markup
    }

    /// The selected passage (empty when the range is out of bounds).
    public var passage: String {
        let ns = documentText as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= ns.length else { return "" }
        return ns.substring(with: range)
    }

    var resolvedMarkup: TextMarkup { markup ?? TextMarkup.detect(documentText, fileName: fileName) }
}

public enum SelectionRewrite {
    public static let startMarker = "<<<REWRITE_START>>>"
    public static let endMarker = "<<<REWRITE_END>>>"
    /// Characters of the surrounding document sent with the passage. Longer
    /// documents are cut to a window around the selection.
    public static let documentLimit = 120_000
    /// Characters of the other version sent as background.
    public static let otherVersionLimit = 80_000

    // MARK: Messages

    public static func messages(for spec: SelectionRewriteSpec) -> RewritePrompt.Messages {
        RewritePrompt.Messages(
            context: ReferenceContext.block(spec.references),
            system: system(spec),
            user: contextBlock(spec) + "\n\nWrite the replacement for this passage."
        )
    }

    /// Second pass for a passage: facts, fit with the surrounding text, tells.
    public static func auditMessages(draft: String, spec: SelectionRewriteSpec, flagged: [String] = []) -> RewritePrompt.Messages {
        let flaggedNote = flagged.isEmpty ? "" : "\n\nAn automatic scan flagged these in the draft; rework each sentence that contains one (don't just swap the word for a synonym): " + flagged.prefix(20).map { "“\($0)”" }.joined(separator: ", ") + "."
        let user = """
        \(contextBlock(spec))

        Here is a draft replacement for that passage:
        <draft>
        \(draft)
        </draft>

        Check the draft in three steps, silently:
        1. Did it drop or change any fact, name, number, date, quote, citation or claim from the original passage? Restore anything lost. Remove anything invented.
        2. Does it fit where it goes? It must join up with the text just before and just after the markers, use the document's terms, notation and tense, and not repeat what the surrounding text already says.
        3. Read it as a sharp human editor. Rewrite any sentence that still sounds machine-written: "not X but Y" contrasts, summary closers, groups of three, em dashes, -ing tails, "serves as" instead of "is", stacked hedges.\(flaggedNote)

        Then output only the corrected replacement for the passage, nothing else.
        """
        return RewritePrompt.Messages(context: ReferenceContext.block(spec.references), system: system(spec), user: user)
    }

    // MARK: Pieces

    static func system(_ spec: SelectionRewriteSpec) -> String {
        var parts: [String] = [RewritePrompt.role]
        let task = describePlaceholders(spec.instructions.trimmingCharacters(in: .whitespacesAndNewlines))
        if !task.isEmpty { parts.append("## Task\n" + task + "\nApply this to the marked passage only.") }
        parts.append("""
        ## Rewriting one passage in context
        You are rewriting one passage inside a longer document, not the whole document. You get the document with the passage marked between \(startMarker) and \(endMarker).
        - Rewrite only the marked passage. Read the text around it so your version fits in seamlessly: it must follow on naturally from the text just before the start marker and lead into the text just after the end marker.
        - If the passage starts or ends in the middle of a sentence, start and end your replacement at the same point, so it joins up grammatically with the words around it.
        - Stay consistent with the rest of the document\(spec.references.isEmpty ? "" : " and the reference documents"): the same terms, notation, abbreviations (an abbreviation defined earlier stays abbreviated), tense, person, spelling variant and citation style.
        - Don't repeat a point the surrounding text already makes, and don't introduce something the text after the passage introduces.
        - Keep every substantive point the passage makes; cut only empty wording, not claims. Stay within about a third of its length unless the task says otherwise.
        """)
        parts.append("## How much to change\n" + spec.strength.instruction)
        parts.append(RewritePrompt.fidelityRules.replacingOccurrences(of: "source text", with: "passage"))
        let markup = spec.resolvedMarkup
        if let rules = markup.rules { parts.append(rules) }
        if spec.avoidAITells {
            parts.append(RewritePrompt.aiTellGuidance(sourcesUseDashes: markup.usesEmDashes(spec.passage), markup: markup))
        }
        let notes = spec.extraNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { parts.append("## Extra instructions from the user\n" + notes) }
        parts.append("""
        ## Output
        - Output only the replacement for the marked passage: no markers, none of the surrounding text, no preamble or comments, no quotation marks or code fences around it.
        - Keep the passage's formatting: line breaks, paragraph breaks, list markers and markup stay as they are unless the task says otherwise.
        """)
        return parts.joined(separator: "\n\n")
    }

    /// The other version (optional), the marked document and the passage again.
    static func contextBlock(_ spec: SelectionRewriteSpec) -> String {
        var parts: [String] = []
        if let other = spec.otherText, !other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var text = other
            if (text as NSString).length > otherVersionLimit {
                text = (text as NSString).substring(to: otherVersionLimit) + "\n[… rest omitted …]"
            }
            parts.append("""
            The user is comparing two versions of this text. For background, here is the other version, “\(spec.otherTitle)”. Don't edit it; rewrite the passage in “\(spec.documentTitle)”.
            <other_version title="\(ReferenceContext.attributeSafe(spec.otherTitle))">
            \(text)
            </other_version>
            """)
        }
        parts.append("""
        <document title="\(ReferenceContext.attributeSafe(spec.documentTitle))">
        \(markedDocument(spec))
        </document>
        """)
        parts.append("""
        The passage to rewrite, exactly as marked above:
        <passage>
        \(spec.passage)
        </passage>
        """)
        return parts.joined(separator: "\n\n")
    }

    /// The document with markers around the passage, cut to a window around
    /// it when the document is very long.
    static func markedDocument(_ spec: SelectionRewriteSpec) -> String {
        let ns = spec.documentText as NSString
        let range = spec.range
        guard range.location != NSNotFound, NSMaxRange(range) <= ns.length else { return spec.documentText }
        var start = 0, end = ns.length
        let budget = max(0, documentLimit - range.length)
        if ns.length - range.length > budget {
            // Two thirds before the passage (what it must follow), a third after.
            let before = min(range.location, max(budget * 2 / 3, budget - (ns.length - NSMaxRange(range))))
            let after = min(ns.length - NSMaxRange(range), budget - before)
            start = snapToLineStart(ns, range.location - before, limit: range.location)
            end = snapToLineEnd(ns, NSMaxRange(range) + after, limit: NSMaxRange(range))
        }
        var out = ""
        if start > 0 { out += "[… earlier part of the document omitted …]\n" }
        out += ns.substring(with: NSRange(location: start, length: range.location - start))
        out += startMarker + ns.substring(with: range) + endMarker
        out += ns.substring(with: NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range)))
        if end < ns.length { out += "\n[… later part of the document omitted …]" }
        return out
    }

    /// Moves a cut forward to the next line start, never past `limit`.
    private static func snapToLineStart(_ ns: NSString, _ index: Int, limit: Int) -> Int {
        guard index > 0 else { return 0 }
        let length = min(2_000, limit - index)
        guard length > 0 else { return index }
        let r = ns.range(of: "\n", options: [], range: NSRange(location: index, length: length))
        return r.location == NSNotFound ? index : NSMaxRange(r)
    }

    /// Moves a cut back to the previous line end, never before `limit`.
    private static func snapToLineEnd(_ ns: NSString, _ index: Int, limit: Int) -> Int {
        guard index < ns.length else { return ns.length }
        let lower = max(limit, index - 2_000)
        guard index > lower else { return index }
        let r = ns.range(of: "\n", options: .backwards, range: NSRange(location: lower, length: index - lower))
        return r.location == NSNotFound ? index : r.location
    }

    /// Custom prompts written for whole texts may use placeholders; in a
    /// passage rewrite they become descriptions instead.
    static func describePlaceholders(_ s: String) -> String {
        s.replacingOccurrences(of: "{{text}}", with: "the marked passage")
            .replacingOccurrences(of: "{{left}}", with: "the marked passage")
            .replacingOccurrences(of: "{{right}}", with: "the marked passage")
            .replacingOccurrences(of: "{{left_title}}", with: "the document")
            .replacingOccurrences(of: "{{right_title}}", with: "the document")
    }

    // MARK: Putting the answer back

    /// The model's answer, trimmed and wrapped in the same leading and
    /// trailing whitespace as the passage it replaces (so paragraph breaks
    /// around a selected paragraph survive).
    public static func fit(_ replacement: String, replacing original: String) -> String {
        let core = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return core }
        let leading = original.prefix { $0.isWhitespace }
        let trailing = String(original.reversed().prefix { $0.isWhitespace }.reversed())
        return String(leading) + core + trailing
    }

    /// Where `passage` is in `text` now: at `range` if it's still there,
    /// otherwise the occurrence closest to it. nil when it's gone.
    public static func locate(_ passage: String, in text: String, near range: NSRange) -> NSRange? {
        let ns = text as NSString
        guard !passage.isEmpty else { return nil }
        if range.location != NSNotFound, NSMaxRange(range) <= ns.length, ns.substring(with: range) == passage { return range }
        var best: NSRange?
        var search = NSRange(location: 0, length: ns.length)
        while true {
            let found = ns.range(of: passage, options: .literal, range: search)
            guard found.location != NSNotFound else { break }
            if best == nil || abs(found.location - range.location) < abs(best!.location - range.location) { best = found }
            let next = found.location + 1
            guard next < ns.length else { break }
            search = NSRange(location: next, length: ns.length - next)
        }
        return best
    }

    /// `text` with `range` replaced, or nil if the range doesn't fit.
    public static func replacing(_ range: NSRange, in text: String, with replacement: String) -> String? {
        let ns = text as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= ns.length else { return nil }
        return ns.replacingCharacters(in: range, with: replacement)
    }
}
