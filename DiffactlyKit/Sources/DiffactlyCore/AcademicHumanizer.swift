import Foundation

/// Guidance for rewriting scholarly text (papers, theses, rebuttals, funding
/// proposals) so it loses its machine-written tells without losing the
/// precise, evidence-bound voice that academic writing needs.
///
/// Adapted from the open-source academic-humanizer skill
/// (AIScientists-Dev/academic-humanizer, MIT). The skill is written for an
/// agent that audits a manuscript and reports a change log; here its layers
/// are recast as rules for a single rewrite that returns only the text. Two
/// rules are tightened to fit that: an evidence pointer may only be one the
/// text already contains (the model can't look anything up), and nothing is
/// reported back, so a claim without support is softened rather than flagged.
///
/// It layers onto any rewrite task. With a task that restructures heavily
/// (paraphrasing or a strong rewrite) it keeps the reconstruction inside
/// scholarly limits; see `restructuring`.
public enum AcademicHumanizer {

    // MARK: Guidance

    /// The section added to the system prompt.
    /// - Parameter withTellGuidance: the general "signs of AI writing"
    ///   section is in the prompt too, so this one says which wins.
    public static func guidance(strength: RewriteStrength, markup: TextMarkup = .plain, withTellGuidance: Bool = true) -> String {
        let precedence = withTellGuidance
            ? " Where this section disagrees with “Avoid the signs of AI writing” (its word list, its advice on hedges and on sentence rhythm), this section wins."
            : ""
        let dash = markup == .latex ? "em dashes (--- in LaTeX, or —)" : "em dashes (—)"
        let range = markup == .latex ? "4--7" : "4–7"
        var parts = ["""
        ## Academic voice
        Treat the text as scholarly writing: a paper, thesis, rebuttal or funding proposal. Academic prose already has a correct human voice: neutral, precise, usually first-person plural, with every claim tied to its evidence. Remove the machine-written tells without making the text casual. Never add opinion, humour, contractions, rhetorical questions or personality.\(precedence)
        The discipline to enforce: every claim earns its number, figure or citation, and no verb is stronger than its evidence.

        ### Academic tells to fix
        - Over-claiming verbs. Empirical work shows or provides evidence; it does not prove, establish, confirm or guarantee. Downgrade "prove", "demonstrate" and "guarantee" unless the text really contains a proof, and drop "significantly" where no test or number backs it.
        - Significance hype: "paves the way for", "a crucial step toward", "has the potential to revolutionize", "opens new avenues", "sheds light on", "of paramount importance", "bridges the gap". Say which specific problem or failure the work addresses.
        - Empty intensifiers: "extensive experiments", "comprehensive evaluation", "a wide range of", "numerous", "various". Replace with the count or the names when the text gives them; otherwise drop the intensifier.
        - Novelty padding: "novel" more than once per section, "to the best of our knowledge", "for the first time". State what prior work does not do.
        - Formulaic openers: "In recent years, X has attracted increasing attention", "With the rapid development of…", "Despite recent advances,…". Open on the actual limitation or question.
        - Connective chains: consecutive sentences starting with Moreover, Furthermore, Additionally or In particular. Let the logic carry.
        - Contribution lists that restate the abstract ("a novel method; extensive experiments; strong results"). Each item names its specific result, using only results the text contains.
        - Hedging by vagueness: "somewhat", "relatively", "fairly", "to some extent", "quite". Use the number when the text has one, or cut the word.
        - Boilerplate emphasis: "It is worth noting that", "It should be emphasized that", "Notably,", "Importantly,". If it matters, the sentence shows it.
        - Clause-stacked sentences: past about 30 words, or three or more subordinate clauses chained with "which", "that", "while", "with". Split them, one idea per sentence, and cut clauses that carry no weight.
        - Remove \(dash) used as sentence punctuation entirely, even where the source uses them: recast with commas, colons, parentheses or separate sentences. Dashes in number ranges (\(range)) stay.

        ### Keep these (do not over-correct)
        - Evidence-tied hedging is correct and required: keep "suggests", "is consistent with", "we hypothesize that", "may indicate", "appears to" wherever the claim is uncertain. Never strengthen a hedge: "the results suggest X" must not become "the results show X".
        - Passive voice where the actor is irrelevant ("Samples were normalized to total protein").
        - First-person plural "we".
        - Semicolons and the occasional list of three.
        - Formal definitions, named methods, datasets and metrics, technical terms, notation, equations and symbols stay verbatim. A word from the avoid list stays when it is the technical term (a robust estimator, the loss landscape, statistical significance, leverage in regression).
        - Every citation stays, with its key or number unchanged and attached to the same claim. Do not merge, drop, reorder or invent citations.
        - Cover everything the source covers: the same sections and paragraphs, in the same order.

        ### Claim and evidence
        For each empirical claim, check that the verb matches the strength of the evidence given for it.
        - A verb stronger than its evidence: downgrade it and scope the claim to what was tested ("on these three datasets", "in this cohort").
        - A claim with no number, figure, table or citation beside it: point to the evidence if the text already contains it (the same passage, the surrounding document or a reference document); otherwise soften the claim to what the text supports.
        - Vague magnitude ("a large improvement"): use the number or range the text gives, attributed to its metric and baseline. If the text gives none, leave the magnitude vague and drop the inflated adjective. Never supply a number, result, table or figure reference of your own.

        ### Voice and venue
        If the reference documents include the author's earlier writing, match it: sentence rhythm, connective habits, how and where they hedge, how they open sections, notation and recurring phrasings. Match the venue's register when it is stated (machine-learning conferences: terse and results-forward; general science journals: more expository). Without either, write clean, precise prose in the register the text already has.

        ### Funding proposals
        If the text is a funding proposal (an NSF Project Summary or Description, an NIH Specific Aims page, a fellowship or foundation application), it is sold on vision plus feasibility, so the discipline changes from claim and evidence to claim and feasibility.
        - Keep the vision. Ambition language ("long-term goal", "transformative", "establish a foundation") is expected in a proposal and stays wherever a plan, preliminary data, prior work or a named collaborator backs it. Scale a claim down only where the text offers no such footing.
        - Vague importance ("this is an important and timely problem"): say what fails, and for whom, without the work.
        - Keep run-in lead-ins (Goal:, Motivation:, Aim 2:), review-criteria headings (Overview, Intellectual Merit, Broader Impacts), aims posed as questions and the team's track record where they stand; reviewers skim by them.
        - State the central hypothesis as a commitment. Calibrated hedging belongs in the interpretation of results, not in the hypothesis.
        - Never invent preliminary results, prior funding, partners or letters of support.
        """]
        if let restructuring = restructuring(strength) { parts.append(restructuring) }
        return parts.joined(separator: "\n\n")
    }

    /// How a heavy rewrite (paraphrasing or a strong rewrite)
    /// reconstructs scholarly text; nil for a light one, which leaves most
    /// sentences alone.
    static func restructuring(_ strength: RewriteStrength) -> String? {
        guard strength != .light else { return nil }
        return """
        ### Restructuring scholarly text
        When the task or the strength above calls for rebuilding sentences (paraphrasing or a strong rewrite), rebuild them inside these limits:
        - Change the syntax, clause order, sentence boundaries and connectors of the prose between the fixed points. The fixed points are the terms, names, notation, equations, numbers, quotations and citations listed above; they keep their exact form.
        - Keep each paragraph's line of argument (claim, then evidence, then interpretation) and the order of paragraphs. Reordering clauses inside a sentence is fine; moving a result away from the claim it supports is not.
        - Keep every hedge at the strength the source gives it, and every comparison pointing the same way against the same baseline.
        - Vary sentence length the way careful academic writers do: split clause-stacked sentences and let a short declarative sentence state a result. Do not add fragments, asides or conversational rhythm to create variety.
        """
    }

    // MARK: Checking a draft

    /// Phrases that mark academic over-claiming or padding. Lower-case;
    /// matched case-insensitively on word boundaries. Kept to wording that
    /// is hype wherever it appears, so a hit is always worth a rework.
    public static let phrases: [String] = [
        "paves the way", "pave the way", "paving the way",
        "sheds light on", "shed light on", "shedding light on",
        "of paramount importance", "bridges the gap", "bridge the gap", "bridging the gap",
        "opens new avenues", "open new avenues", "opens up new avenues", "opening new avenues",
        "potential to revolutionize", "potential to revolutionise",
        "a crucial step toward", "a crucial step towards", "a pivotal step toward", "a pivotal step towards",
        "to the best of our knowledge", "for the first time",
        "extensive experiments", "comprehensive experiments", "thorough experiments",
        "extensive evaluation", "extensive evaluations",
        "in recent years", "with the rapid development of", "attracted increasing attention",
        "has attracted considerable attention", "has received increasing attention",
        "despite recent advances", "it should be emphasized that", "it should be emphasised that",
        "it is worth noting that", "it is noteworthy that", "universally superior",
        "state-of-the-art performance",
    ]

    private static let pattern: NSRegularExpression? = {
        let body = phrases.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        return try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}-])(?:"# + body + #")(?![\p{L}\p{N}-])"#, options: [.caseInsensitive])
    }()

    /// The distinct academic tells in `text` (lower-cased), in order of first appearance.
    public static func flaggedPhrases(in text: String) -> [String] {
        guard let pattern else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var out: [String] = []
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let phrase = ns.substring(with: match.range).lowercased()
            if seen.insert(phrase).inserted { out.append(phrase) }
        }
        return out
    }

    /// The extra step a second pass runs on an academic rewrite.
    static func auditStep(_ number: Int) -> String {
        """
        \(number). Read it as a reviewer in the field. Is any verb stronger than its evidence, or stronger than the source's own wording ("suggests" turned into "shows" or "proves")? Restore the source's level of hedging. Is every citation still there, unchanged and attached to the same claim, and every term, symbol and equation in its exact form? Did the draft turn casual (contractions, asides, fragments) or keep academic padding ("extensive experiments", "paves the way", "to the best of our knowledge", "In recent years…", a "Moreover/Furthermore" chain, an em dash)? Fix each one.
        """
    }
}
