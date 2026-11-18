import XCTest
@testable import DiffactlyCore

final class AITellsTests: XCTestCase {

    func testFindsVocabularyPhrasesAndStructures() {
        let text = "In today's fast-paced world, this tool is not just fast, but also robust. Let's delve deeper."
        let report = AITells.scan(text)
        let found = report.hits.map { $0.text.lowercased() }
        XCTAssertTrue(found.contains("in today's fast-paced world"))
        XCTAssertTrue(found.contains("robust"))
        XCTAssertTrue(found.contains("delve"))
        XCTAssertTrue(report.hits.contains { $0.category == .structure })
    }

    func testPhraseWinsOverItsWord() {
        let report = AITells.scan("We delve into the data.")
        XCTAssertEqual(report.hits.count, 1)
        XCTAssertEqual(report.hits.first?.text, "delve into")
        XCTAssertEqual(report.hits.first?.category, .phrase)
    }

    func testWholeWordsOnly() {
        // "realms" isn't listed, "underscored" isn't, and hyphenated compounds don't match.
        let report = AITells.scan("Unrobust code and pre-delve notes.")
        XCTAssertTrue(report.hits.isEmpty, "\(report.hits)")
    }

    func testCurlyApostrophesMatch() {
        XCTAssertFalse(AITells.scan("It’s worth noting that it rains.").hits.isEmpty)
    }

    func testRangesAreUTF16() {
        let text = "👋🏽 tapestry"
        let hit = AITells.scan(text).hits.first
        XCTAssertEqual((text as NSString).substring(with: hit!.range), "tapestry")
    }

    func testCleanHumanTextScoresLow() {
        let text = "I fixed the login bug on Tuesday. It turned out the session cookie expired before the redirect finished, so users bounced back to the form."
        let report = AITells.scan(text)
        XCTAssertEqual(report.hits.count, 0)
        XCTAssertEqual(report.level, .low)
    }

    func testDensityCountsHeavyEmDashUse() {
        let text = "Fast — simple — cheap — done."
        let report = AITells.scan(text)
        XCTAssertEqual(report.emDashes, 3)
        XCTAssertGreaterThan(report.density, 0)
    }

    func testNumberExtractionAndMissingNumbersGuard() {
        let source = "In 2026, revenue rose 61.3% to $1,200 across 5 regions (see \\cite{smith2024} and https://example.com/v2/report)."
        let nums = AITells.extractNumbers(source)
        XCTAssertEqual(nums, ["2026", "61.3%", "$1,200", "5"])

        // Preserved when formatting changes ($1,200 -> 1200, 61.3% -> 61.3 percent)
        let faithful = "Across 5 regions in 2026, revenue climbed 61.3 percent to 1200 dollars."
        XCTAssertTrue(AITells.missingNumbers(from: source, in: faithful).isEmpty)

        // Flagged when rounded or dropped (61.3% -> 61%, 5 dropped)
        let drifted = "In 2026, revenue climbed 61% to $1,200 across the regions."
        XCTAssertEqual(AITells.missingNumbers(from: source, in: drifted), ["61.3%", "5"])
    }

    func testBurstinessCadence() {
        let uniform = """
        The first sentence has exactly nine words in total. \
        The second sentence also has nine words in total. \
        The third sentence again has nine words in total. \
        The fourth sentence still has nine words in total.
        """
        let varied = """
        Short opening. \
        Then a much longer sentence follows that unpacks the entire mechanism in detail across several distinct clauses so the rhythm shifts. \
        It works well. \
        Finally, a medium-length sentence wraps up the point cleanly.
        """
        XCTAssertLessThan(AITells.sentenceBurstinessCV(uniform), 0.1)
        XCTAssertGreaterThan(AITells.sentenceBurstinessCV(varied), 0.5)
    }
}

final class RewritePromptTests: XCTestCase {

    private func spec(source: RewriteSource = .both, weight: Double = 0.5, instructions: String = "Humanize it.") -> RewriteSpec {
        RewriteSpec(leftText: "Left body", rightText: "Right body", leftTitle: "Draft A", rightTitle: "Draft B",
                    source: source, leftWeight: weight, instructions: instructions)
    }

    func testBothSourcesIncludeBothTextsAndTitles() {
        let m = RewritePrompt.messages(for: spec())
        XCTAssertTrue(m.user.contains("Left body"))
        XCTAssertTrue(m.user.contains("Right body"))
        XCTAssertTrue(m.user.contains("title=\"Draft A\""))
        XCTAssertTrue(m.system.contains("Merge the two evenly"))
        XCTAssertTrue(m.system.contains("50% “Draft A”"))
        XCTAssertTrue(m.system.contains("Humanize it."))
    }

    func testSingleSourceOmitsTheOtherText() {
        let m = RewritePrompt.messages(for: spec(source: .right))
        XCTAssertFalse(m.user.contains("Left body"))
        XCTAssertTrue(m.user.contains("Right body"))
    }

    func testWeightPicksTheBase() {
        XCTAssertTrue(RewritePrompt.messages(for: spec(weight: 1)).system.contains("almost entirely on “Draft A”"))
        XCTAssertTrue(RewritePrompt.messages(for: spec(weight: 0.75)).system.contains("Use “Draft A” as the base"))
        XCTAssertTrue(RewritePrompt.messages(for: spec(weight: 0.2)).system.contains("Use “Draft B” as the base"))
        XCTAssertTrue(RewritePrompt.messages(for: spec(weight: 0)).system.contains("almost entirely on “Draft B”"))
    }

    func testPlaceholdersBecomeTheUserMessage() {
        let m = RewritePrompt.messages(for: spec(instructions: "Compare {{left_title}}: {{left}} with {{right_title}}: {{right}}"))
        XCTAssertEqual(m.user, "Compare Draft A: Left body with Draft B: Right body")
        XCTAssertFalse(m.system.contains("## Task"))
    }

    func testDashRuleFollowsTheSource() {
        var s = spec()
        XCTAssertTrue(RewritePrompt.messages(for: s).system.contains("Do not use em dashes"))
        s.leftText = "A — B"
        XCTAssertTrue(RewritePrompt.messages(for: s).system.contains("no more often than the source"))
        s.avoidAITells = false
        XCTAssertFalse(RewritePrompt.messages(for: s).system.contains("em dashes"))
    }

    func testAuditNamesFlaggedPhrases() {
        let m = RewritePrompt.auditMessages(draft: "We delve.", spec: spec(), flagged: ["delve", "pivotal"])
        XCTAssertTrue(m.user.contains("“delve”, “pivotal”"))
        XCTAssertTrue(m.user.contains("<draft>\nWe delve.\n</draft>"))
        XCTAssertFalse(RewritePrompt.auditMessages(draft: "x", spec: spec()).user.contains("automatic scan"))
    }

    func testAuditMessagesIncludeMissingNumbers() {
        let s = spec()
        let m = RewritePrompt.auditMessages(draft: "Draft text.", spec: s, flagged: [], missingNumbers: ["61.3%", "2026"])
        XCTAssertTrue(m.user.contains("“61.3%”, “2026”"))
    }

    // MARK: Academic humanizer

    func testAcademicGuidanceIsOptIn() {
        XCTAssertFalse(RewritePrompt.messages(for: spec()).system.contains("## Academic voice"))
        var s = spec()
        s.academic = true
        let system = RewritePrompt.messages(for: s).system
        XCTAssertTrue(system.contains("## Academic voice"))
        XCTAssertTrue(system.contains("Never strengthen a hedge"))
        XCTAssertTrue(system.contains("Funding proposals"))
        XCTAssertTrue(system.contains("this section wins"), "it overrides the general tell list")
        // It comes after the general tells and before the output rules.
        let tells = system.range(of: "## Avoid the signs of AI writing")!
        let academic = system.range(of: "## Academic voice")!
        let output = system.range(of: "## Output")!
        XCTAssertTrue(tells.lowerBound < academic.lowerBound && academic.lowerBound < output.lowerBound)
    }

    func testAcademicGuidanceStandsAloneWithoutTheTellList() {
        var s = spec()
        s.academic = true
        s.avoidAITells = false
        let system = RewritePrompt.messages(for: s).system
        XCTAssertTrue(system.contains("## Academic voice"))
        XCTAssertFalse(system.contains("this section wins"))
    }

    func testAcademicRestructuringFollowsStrength() {
        var s = spec()
        s.academic = true
        s.strength = .light
        XCTAssertFalse(RewritePrompt.messages(for: s).system.contains("Restructuring scholarly text"))
        s.strength = .strong
        let system = RewritePrompt.messages(for: s).system
        XCTAssertTrue(system.contains("Restructuring scholarly text"))
    }

    func testAcademicDashRuleFollowsMarkup() {
        let latex = AcademicHumanizer.guidance(strength: .moderate, markup: .latex)
        XCTAssertTrue(latex.contains("--- in LaTeX"))
        XCTAssertTrue(latex.contains("4--7"))
        XCTAssertTrue(AcademicHumanizer.guidance(strength: .moderate).contains("4–7"))
    }

    func testAcademicAuditAddsAStep() {
        var s = spec()
        XCTAssertTrue(RewritePrompt.auditMessages(draft: "x", spec: s).user.contains("in two steps"))
        s.academic = true
        let user = RewritePrompt.auditMessages(draft: "x", spec: s).user
        XCTAssertTrue(user.contains("in three steps"))
        XCTAssertTrue(user.contains("3. Read it as a reviewer in the field."))
    }

    func testAcademicPhraseScan() {
        let text = "In recent years, X has grown. This paves the way for Y. To the best of our knowledge, it Paves the Way."
        XCTAssertEqual(AcademicHumanizer.flaggedPhrases(in: text), ["in recent years", "paves the way", "to the best of our knowledge"])
        XCTAssertTrue(AcademicHumanizer.flaggedPhrases(in: "Accuracy rises by 4 points over the baseline (Table 2).").isEmpty)
    }

    func testStrengthLevelsAndTransparency() {
        XCTAssertEqual(RewriteStrength.allCases, [.light, .moderate, .strong])
        for strength in RewriteStrength.allCases {
            XCTAssertFalse(strength.transparentSummary.isEmpty)
            var s = spec()
            s.strength = strength
            let m = RewritePrompt.messages(for: s)
            XCTAssertTrue(m.system.contains("Never change, round, approximate, spell out, or drop any number"))
        }
    }

    func testCleanStripsWrappers() {
        XCTAssertEqual(RewritePrompt.clean("Here is the rewritten text:\n\nHello there."), "Hello there.")
        XCTAssertEqual(RewritePrompt.clean("```markdown\n# Title\nBody\n```"), "# Title\nBody")
        XCTAssertEqual(RewritePrompt.clean("<think>plan it</think>\nFinal words."), "Final words.")
        XCTAssertEqual(RewritePrompt.clean("Done text.<think>still going"), "Done text.")
        XCTAssertEqual(RewritePrompt.clean("reasoning…</think>Answer"), "Answer")
        XCTAssertEqual(RewritePrompt.clean("<text title=\"A\">\nBody\n</text>"), "Body")
        // A real first line ending in a colon is kept.
        XCTAssertEqual(RewritePrompt.clean("Ingredients:\n- flour"), "Ingredients:\n- flour")
    }
}

final class LLMClientTests: XCTestCase {

    private func body(_ r: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    private let request = LLMRequest(system: "sys", messages: [LLMMessage(.user, "hi")], temperature: 0.7, maxTokens: 100)

    func testOpenAICompatibleRequest() throws {
        let client = LLMClient(endpoint: LLMEndpoint(kind: .lmStudio, baseURL: "http://localhost:1234/v1/", model: "qwen"))
        let r = try client.makeChatRequest(request, stream: true)
        XCTAssertEqual(r.url?.absoluteString, "http://localhost:1234/v1/chat/completions")
        XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"))
        let b = body(r)
        XCTAssertEqual((b["messages"] as? [[String: Any]])?.first?["role"] as? String, "system")
        XCTAssertEqual(b["max_tokens"] as? Int, 100)
        XCTAssertEqual(b["stream"] as? Bool, true)
    }

    func testAnthropicRequest() throws {
        let client = LLMClient(endpoint: LLMEndpoint(kind: .anthropic, baseURL: LLMProviderKind.anthropic.defaultBaseURL, apiKey: "k", model: "claude-sonnet-5-5"))
        let r = try client.makeChatRequest(request, stream: true)
        XCTAssertEqual(r.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertNotNil(r.value(forHTTPHeaderField: "anthropic-version"))
        XCTAssertEqual((body(r)["system"] as? [[String: Any]])?.first?["text"] as? String, "sys")
    }

    func testGeminiRequest() throws {
        let client = LLMClient(endpoint: LLMEndpoint(kind: .gemini, baseURL: LLMProviderKind.gemini.defaultBaseURL, apiKey: "g", model: "gemini-x"))
        let r = try client.makeChatRequest(request, stream: true)
        XCTAssertEqual(r.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-x:streamGenerateContent?alt=sse")
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-goog-api-key"), "g")
        XCTAssertNotNil(body(r)["systemInstruction"])
    }

    func testCloudProvidersNeedKeysAndModels() {
        let noKey = LLMClient(endpoint: LLMEndpoint(kind: .openAI, baseURL: LLMProviderKind.openAI.defaultBaseURL, model: "m"))
        XCTAssertThrowsError(try noKey.makeChatRequest(request, stream: true)) { XCTAssertEqual($0 as? LLMError, .missingAPIKey("OpenAI")) }
        let noModel = LLMClient(endpoint: LLMEndpoint(kind: .ollama, baseURL: LLMProviderKind.ollama.defaultBaseURL, model: " "))
        XCTAssertThrowsError(try noModel.makeChatRequest(request, stream: true)) { XCTAssertEqual($0 as? LLMError, .missingModel) }
    }

    func testSSEParsing() throws {
        var openAI = SSEParser(style: .openAI)
        XCTAssertEqual(try openAI.consume(#"data: {"choices":[{"delta":{"content":"Hel"}}]}"#), [.text("Hel")])
        XCTAssertEqual(try openAI.consume("data: [DONE]"), [.done])
        XCTAssertEqual(try openAI.consume(": keep-alive"), [])
        XCTAssertEqual(try openAI.consume(#"data: {"choices":[{"delta":{"reasoning_content":"hmm"}}]}"#), [.reasoning("hmm")])
        XCTAssertEqual(try openAI.consume(#"data: {"choices":[{"delta":{"reasoning":"also"}}]}"#), [.reasoning("also")])
        XCTAssertEqual(try openAI.consume(#"data: {"choices":[{"delta":{"content":"end"},"finish_reason":"length"}]}"#), [.text("end"), .truncated])

        var anthropic = SSEParser(style: .anthropic)
        XCTAssertEqual(try anthropic.consume(#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#), [.text("Hi")])
        XCTAssertEqual(try anthropic.consume(#"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"plan"}}"#), [.reasoning("plan")])
        XCTAssertEqual(try anthropic.consume(#"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#), [.truncated])
        XCTAssertEqual(try anthropic.consume(#"data: {"type":"message_stop"}"#), [.done])
        XCTAssertThrowsError(try anthropic.consume(#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#))

        var gemini = SSEParser(style: .gemini)
        XCTAssertEqual(try gemini.consume(#"data: {"candidates":[{"content":{"parts":[{"text":"think","thought":true},{"text":"Yo"}]}}]}"#), [.reasoning("think"), .text("Yo")])
        XCTAssertEqual(try gemini.consume(#"data: {"candidates":[{"content":{"parts":[{"text":"!"}]},"finishReason":"MAX_TOKENS"}]}"#), [.text("!"), .truncated])
    }

    func testModelListParsing() throws {
        let openAI = #"{"data":[{"id":"b"},{"id":"a"}]}"#.data(using: .utf8)!
        XCTAssertEqual(try LLMClient.parseModels(openAI, style: .openAI), ["a", "b"])
        let gemini = #"{"models":[{"name":"models/gemini-pro","supportedGenerationMethods":["generateContent"]},{"name":"models/embed","supportedGenerationMethods":["embedContent"]}]}"#.data(using: .utf8)!
        XCTAssertEqual(try LLMClient.parseModels(gemini, style: .gemini), ["gemini-pro"])
    }

    func testErrorMessageExtraction() {
        XCTAssertEqual(LLMClient.errorMessage(from: #"{"error":{"message":"bad key"}}"#.data(using: .utf8)!), "bad key")
        XCTAssertEqual(LLMClient.errorMessage(from: #"[{"error":{"message":"gemini says no"}}]"#.data(using: .utf8)!), "gemini says no")
    }
}

final class DiffSummaryPromptTests: XCTestCase {

    private func spec(_ left: String, _ right: String, detail: SummaryDetail = .brief, focus: SummaryFocus = .meaning) -> DiffSummarySpec {
        DiffSummarySpec(leftText: left, rightText: right, leftTitle: "v1", rightTitle: "v2",
                        result: DiffEngine.compare(left, right), detail: detail, focus: focus)
    }

    func testIncludesTextsDiffAndStats() {
        let m = DiffSummaryPrompt.messages(for: spec("Ship in 3 weeks.\nSame line.", "Ship in 2 weeks.\nSame line."))
        XCTAssertTrue(m.user.contains("<text title=\"v1\">"))
        XCTAssertTrue(m.user.contains("<diff>"))
        XCTAssertTrue(m.user.contains("-Ship in 3 weeks."))
        XCTAssertTrue(m.user.contains("+Ship in 2 weeks."))
        XCTAssertTrue(m.user.contains("Similarity:"))
        XCTAssertTrue(m.system.contains("“v2” differs from “v1”"))
        XCTAssertTrue(m.system.contains("at most 6 bullets"))
        XCTAssertFalse(m.system.contains("### Tone and style"))
    }

    func testDetailAndFocusChangeTheInstructions() {
        let m = DiffSummaryPrompt.messages(for: spec("a", "b", detail: .detailed, focus: .everything))
        XCTAssertTrue(m.system.contains("as many bullets as there are real differences"))
        XCTAssertTrue(m.system.contains("### Tone and style"))
        XCTAssertTrue(m.system.contains("tone, register"))
    }

    func testLongTextsSendOnlyTheDiff() {
        let long = String(repeating: "word ", count: DiffSummaryPrompt.fullTextLimit / 5 + 10)
        let s = spec(long, long + "\nextra")
        XCTAssertFalse(DiffSummaryPrompt.includesFullTexts(s))
        let m = DiffSummaryPrompt.messages(for: s)
        XCTAssertFalse(m.user.contains("<text title="))
        XCTAssertTrue(m.user.contains("too long to include in full"))
        XCTAssertLessThan(m.user.count, DiffSummaryPrompt.patchLimit + 2_000)
    }

    func testExtraNotesComeBeforeTheStyleRules() {
        var s = spec("a", "b")
        s.extraNotes = "Focus on legal risk."
        let system = DiffSummaryPrompt.messages(for: s).system
        let notes = system.range(of: "Focus on legal risk.")!
        let style = system.range(of: "## Style")!
        XCTAssertLessThan(notes.lowerBound, style.lowerBound)
    }
}

final class SelectionRewriteTests: XCTestCase {

    private let doc = "First paragraph sets up the method.\n\nThe second paragraph is the one we rewrite.\n\nThird paragraph discusses results."

    private func spec(_ passage: String = "The second paragraph is the one we rewrite.", in text: String? = nil, other: String? = nil, references: [ReferenceDocument] = []) -> SelectionRewriteSpec {
        let text = text ?? doc
        let range = (text as NSString).range(of: passage)
        return SelectionRewriteSpec(documentText: text, documentTitle: "Draft", range: range, otherText: other,
                                    otherTitle: "Old", instructions: "Humanize it.", references: references)
    }

    func testMarksThePassageInTheFullDocument() {
        let m = SelectionRewrite.messages(for: spec())
        XCTAssertTrue(m.user.contains("sets up the method.\n\n<<<REWRITE_START>>>The second paragraph is the one we rewrite.<<<REWRITE_END>>>\n\nThird paragraph"))
        XCTAssertTrue(m.user.contains("<passage>\nThe second paragraph is the one we rewrite.\n</passage>"))
        XCTAssertTrue(m.system.contains("Rewrite only the marked passage"))
        XCTAssertTrue(m.system.contains("Humanize it.\nApply this to the marked passage only."))
        XCTAssertFalse(m.user.contains("<other_version"))
        XCTAssertEqual(m.context, "")
    }

    func testOtherVersionAndReferencesAreIncluded() {
        let m = SelectionRewrite.messages(for: spec(other: "Old wording.", references: [ReferenceDocument(name: "2_methods.tex", text: "We define \\(x\\) as…")]))
        XCTAssertTrue(m.user.contains("<other_version title=\"Old\">\nOld wording.\n</other_version>"))
        XCTAssertTrue(m.context.contains("<document name=\"2_methods.tex\">"))
        XCTAssertTrue(m.system.contains("and the reference documents"))
        // The other version comes before the document, the task last.
        XCTAssertLessThan(m.user.range(of: "<other_version")!.lowerBound, m.user.range(of: "<document")!.lowerBound)
        XCTAssertTrue(m.user.hasSuffix("Write the replacement for this passage."))
    }

    func testLongDocumentsAreCutToAWindowAroundThePassage() {
        let filler = String(repeating: "Filler line of text.\n", count: 12_000) // ~250k chars
        let text = filler + "TARGET passage here.\n" + filler
        let marked = SelectionRewrite.markedDocument(spec("TARGET passage here.", in: text))
        XCTAssertLessThanOrEqual(marked.count, SelectionRewrite.documentLimit + 200)
        XCTAssertTrue(marked.contains("<<<REWRITE_START>>>TARGET passage here.<<<REWRITE_END>>>"))
        XCTAssertTrue(marked.hasPrefix("[… earlier part of the document omitted …]\nFiller"))
        XCTAssertTrue(marked.hasSuffix("\n[… later part of the document omitted …]"))
    }

    func testWindowAtTheStartOfALongDocument() {
        let text = "TARGET first.\n" + String(repeating: "Filler line of text.\n", count: 12_000)
        let marked = SelectionRewrite.markedDocument(spec("TARGET first.", in: text))
        XCTAssertTrue(marked.hasPrefix("<<<REWRITE_START>>>TARGET first.<<<REWRITE_END>>>"))
        XCTAssertLessThanOrEqual(marked.count, SelectionRewrite.documentLimit + 200)
    }

    func testFitKeepsSurroundingWhitespace() {
        XCTAssertEqual(SelectionRewrite.fit("  New text.\n", replacing: "\n\nOld text.\n\n"), "\n\nNew text.\n\n")
        XCTAssertEqual(SelectionRewrite.fit("New", replacing: "Old"), "New")
        XCTAssertEqual(SelectionRewrite.fit(" New ", replacing: "   "), "New")
    }

    func testLocateAndReplace() {
        let text = "a b a b a"
        let range = NSRange(location: 4, length: 1)
        XCTAssertEqual(SelectionRewrite.locate("a", in: text, near: range), range)
        // Text moved: the nearest occurrence wins.
        XCTAssertEqual(SelectionRewrite.locate("a", in: "x" + text, near: range), NSRange(location: 5, length: 1))
        XCTAssertNil(SelectionRewrite.locate("zzz", in: text, near: range))
        XCTAssertEqual(SelectionRewrite.replacing(NSRange(location: 2, length: 1), in: text, with: "X"), "a X a b a")
        XCTAssertNil(SelectionRewrite.replacing(NSRange(location: 20, length: 1), in: text, with: "X"))
    }

    func testCleanRemovesEchoedMarkers() {
        XCTAssertEqual(RewritePrompt.clean("<<<REWRITE_START>>>New text.<<<REWRITE_END>>>"), "New text.")
        XCTAssertEqual(RewritePrompt.clean("<passage>\nNew text.\n</passage>"), "New text.")
    }

    func testAcademicSelectionRewrite() {
        var s = spec()
        XCTAssertFalse(SelectionRewrite.messages(for: s).system.contains("## Academic voice"))
        s.academic = true
        XCTAssertTrue(SelectionRewrite.messages(for: s).system.contains("## Academic voice"))
        let user = SelectionRewrite.auditMessages(draft: "x", spec: s).user
        XCTAssertTrue(user.contains("in four steps"))
        XCTAssertTrue(user.contains("4. Read it as a reviewer in the field."))
    }

    func testAuditKeepsTheContextAndNamesTells() {
        let m = SelectionRewrite.auditMessages(draft: "A pivotal draft.", spec: spec(), flagged: ["pivotal"])
        XCTAssertTrue(m.user.contains("<<<REWRITE_START>>>"))
        XCTAssertTrue(m.user.contains("<draft>\nA pivotal draft.\n</draft>"))
        XCTAssertTrue(m.user.contains("“pivotal”"))
    }
}

final class MarkupAndReferenceTests: XCTestCase {

    func testLaTeXDetection() {
        XCTAssertEqual(TextMarkup.detect("As shown in \\cite{x}, see Section~\\ref{sec:a}."), .latex)
        XCTAssertEqual(TextMarkup.detect("Plain prose with a \\ backslash."), .plain)
        XCTAssertEqual(TextMarkup.detect("anything", fileName: "1_introduction.tex"), .latex)
    }

    func testLaTeXRulesAndDashesReachThePrompt() {
        let latex = "We extend prior work~\\cite{a} --- see \\ref{b} --- to new data."
        let m = RewritePrompt.messages(for: RewriteSpec(leftText: latex, rightText: "", source: .left, instructions: "x"))
        XCTAssertTrue(m.system.contains("## LaTeX source"))
        XCTAssertTrue(m.system.contains("no more often than the source does"))
        XCTAssertFalse(RewritePrompt.messages(for: RewriteSpec(leftText: "Plain text.", rightText: "", source: .left, instructions: "x")).system.contains("LaTeX"))
    }

    func testLaTeXEmDashesAreCountedButRulesAreNot() {
        XCTAssertEqual(AITells.scan("one --- two --- three").emDashes, 2)
        XCTAssertEqual(AITells.scan("%-----------\nsection").emDashes, 0)
    }

    func testReferenceBlockAndBudget() {
        XCTAssertEqual(ReferenceContext.block([]), "")
        XCTAssertEqual(ReferenceContext.block([ReferenceDocument(name: "empty", text: "  \n")]), "")
        let block = ReferenceContext.block([ReferenceDocument(name: "a\"b.tex", text: "Alpha")])
        XCTAssertTrue(block.contains("<document name=\"a'b.tex\">\nAlpha\n</document>"))
        let big = String(repeating: "x", count: ReferenceContext.characterLimit)
        let cut = ReferenceContext.block([ReferenceDocument(name: "big", text: big), ReferenceDocument(name: "late.tex", text: "y")])
        XCTAssertTrue(cut.contains("Left out to fit the context: late.tex"))
    }

    func testWholeRewriteAndSummaryCarryReferences() {
        let refs = [ReferenceDocument(name: "paper.tex", text: "Background")]
        XCTAssertTrue(RewritePrompt.messages(for: RewriteSpec(leftText: "a", rightText: "b", instructions: "x", references: refs)).context.contains("paper.tex"))
        let summary = DiffSummaryPrompt.messages(for: DiffSummarySpec(leftText: "a", rightText: "b", result: DiffEngine.compare("a", "b"), references: refs))
        XCTAssertTrue(summary.context.contains("Background"))
    }
}

final class ThinkingEffortTests: XCTestCase {

    private func body(_ kind: LLMProviderKind, _ thinking: ThinkingEffort) throws -> [String: Any] {
        let client = LLMClient(endpoint: LLMEndpoint(kind: kind, baseURL: kind.defaultBaseURL, apiKey: "k", model: "m", thinking: thinking))
        let r = try client.makeChatRequest(LLMRequest(system: "s", messages: [LLMMessage(.user, "hi")]), stream: true)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any])
    }

    func testFullSendsNothing() throws {
        for kind in LLMProviderKind.allCases {
            let b = try body(kind, .full)
            for key in ["reasoning_effort", "reasoning", "thinking_budget", "chat_template_kwargs", "thinking"] { XCTAssertNil(b[key], "\(kind) \(key)") }
            XCTAssertNil((b["generationConfig"] as? [String: Any])?["thinkingConfig"])
        }
    }

    func testOMLXCapsThinkingTokens() throws {
        let low = try body(.oMLX, .low)
        XCTAssertEqual(low["thinking_budget"] as? Int, 2_048)
        XCTAssertEqual(low["reasoning_effort"] as? String, "low")
        XCTAssertEqual(try body(.oMLX, .medium)["thinking_budget"] as? Int, 8_192)
        let off = try body(.oMLX, .off)
        XCTAssertEqual((off["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], false)
        XCTAssertNil(off["thinking_budget"])
    }

    func testOtherLocalServersGetEffortOrTheTemplateSwitch() throws {
        XCTAssertEqual(try body(.ollama, .low)["reasoning_effort"] as? String, "low")
        XCTAssertNil(try body(.llamaCpp, .low)["thinking_budget"])
        XCTAssertEqual((try body(.llamaCpp, .off)["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], false)
    }

    func testCloudProviders() throws {
        XCTAssertEqual(try body(.openAI, .medium)["reasoning_effort"] as? String, "medium")
        XCTAssertNil(try body(.openAI, .off)["reasoning_effort"], "OpenAI isn't offered Off")
        XCTAssertEqual((try body(.openRouter, .low)["reasoning"] as? [String: String])?["effort"], "low")
        XCTAssertEqual((try body(.openRouter, .off)["reasoning"] as? [String: Bool])?["enabled"], false)
        let gemini = try XCTUnwrap(try body(.gemini, .low)["generationConfig"] as? [String: Any])
        XCTAssertEqual((gemini["thinkingConfig"] as? [String: Int])?["thinkingBudget"], 2_048)
        XCTAssertNil(try body(.anthropic, .low)["thinking"])
        XCTAssertEqual(ThinkingEffort.options(for: .anthropic), [])
    }
}

final class OutputBudgetTests: XCTestCase {

    func testCloudKeepsItsBudget() {
        XCTAssertEqual(OutputBudget.tokens(answerTokens: 4_000, cloud: 12_000, inputTokens: 5_000, contextLength: 200_000, isLocal: false), 12_000)
    }

    func testLocalUsesTheRoomLeftInTheWindow() {
        // Qwen on oMLX with a 32k window: a 12k budget ran out mid-thought.
        XCTAssertEqual(OutputBudget.tokens(answerTokens: 4_000, cloud: 12_055, inputTokens: 5_000, contextLength: 32_768, isLocal: true),
                       32_768 - 5_000 - OutputBudget.windowMargin)
    }

    func testLocalIsCappedOnHugeWindows() {
        XCTAssertEqual(OutputBudget.tokens(answerTokens: 1_000, cloud: 8_192, inputTokens: 2_000, contextLength: 262_144, isLocal: true), OutputBudget.localFloor)
        XCTAssertEqual(OutputBudget.tokens(answerTokens: 10_000, cloud: 32_000, inputTokens: 12_000, contextLength: 262_144, isLocal: true), 80_000)
    }

    func testLocalWithoutAKnownWindowStillGetsTheFloor() {
        XCTAssertEqual(OutputBudget.tokens(answerTokens: 1_000, cloud: 8_192, inputTokens: 2_000, contextLength: nil, isLocal: true), OutputBudget.localFloor)
    }

    func testOverfullWindowLeavesAMinimum() {
        XCTAssertEqual(OutputBudget.tokens(answerTokens: 1_000, cloud: 8_192, inputTokens: 9_000, contextLength: 8_192, isLocal: true), 1_024)
    }
}

final class LLMContextTests: XCTestCase {

    private func body(_ r: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    private let request = LLMRequest(context: "REFS", system: "SYS", messages: [LLMMessage(.user, "hi")])

    func testAnthropicCachesTheContextBlock() throws {
        let client = LLMClient(endpoint: LLMEndpoint(kind: .anthropic, baseURL: LLMProviderKind.anthropic.defaultBaseURL, apiKey: "k", model: "m"))
        let system = try XCTUnwrap(body(try client.makeChatRequest(request, stream: true))["system"] as? [[String: Any]])
        XCTAssertEqual(system.count, 2)
        XCTAssertEqual(system[0]["text"] as? String, "REFS")
        XCTAssertEqual((system[0]["cache_control"] as? [String: String])?["type"], "ephemeral")
        XCTAssertEqual(system[1]["text"] as? String, "SYS")
        XCTAssertNil(system[1]["cache_control"])
    }

    func testOpenAICompatiblePutsContextFirstInOneSystemMessage() throws {
        let client = LLMClient(endpoint: LLMEndpoint(kind: .oMLX, baseURL: LLMProviderKind.oMLX.defaultBaseURL, model: "m"))
        let messages = try XCTUnwrap(body(try client.makeChatRequest(request, stream: true))["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.filter { $0["role"] as? String == "system" }.count, 1)
        XCTAssertEqual(messages[0]["content"] as? String, "REFS\n\nSYS")
    }

    func testGeminiSendsContextAsTheFirstSystemPart() throws {
        let client = LLMClient(endpoint: LLMEndpoint(kind: .gemini, baseURL: LLMProviderKind.gemini.defaultBaseURL, apiKey: "g", model: "m"))
        let parts = try XCTUnwrap((body(try client.makeChatRequest(request, stream: true))["systemInstruction"] as? [String: Any])?["parts"] as? [[String: String]])
        XCTAssertEqual(parts.map { $0["text"] }, ["REFS", "SYS"])
    }

    func testModelContextLengths() throws {
        let omlx = #"{"data":[{"id":"qwen","max_model_len":32768},{"id":"plain"}]}"#.data(using: .utf8)!
        XCTAssertEqual(try LLMClient.parseModelInfo(omlx, style: .openAI), [LLMModelInfo(id: "plain"), LLMModelInfo(id: "qwen", contextLength: 32768)])
        let router = #"{"data":[{"id":"a/b","context_length":200000}]}"#.data(using: .utf8)!
        XCTAssertEqual(try LLMClient.parseModelInfo(router, style: .openAI).first?.contextLength, 200000)
        let gemini = #"{"models":[{"name":"models/g","inputTokenLimit":1048576,"supportedGenerationMethods":["generateContent"]}]}"#.data(using: .utf8)!
        XCTAssertEqual(try LLMClient.parseModelInfo(gemini, style: .gemini), [LLMModelInfo(id: "g", contextLength: 1048576)])
    }
}

/// Passage rewrites that draw on text the user highlighted.
final class HighlightedSourcePromptTests: XCTestCase {

    func testHighlightedCounterpartIsDescribedAsTheUsersChoice() {
        let doc = "Intro. The passage to rewrite. Outro. An extra bit."
        let range = (doc as NSString).range(of: "The passage to rewrite.")
        let spec = SelectionRewriteSpec(documentText: doc, range: range, otherTitle: "Original",
                                        counterpart: "Hand-picked text.", counterpartIsMarked: true,
                                        markedExcerpts: ["An extra bit.", "The passage to rewrite.", "  "],
                                        passageWeight: 0.5, instructions: "Humanize.")
        let m = SelectionRewrite.messages(for: spec)
        XCTAssertTrue(m.user.contains("The text the user highlighted in “Original” for this passage:"), m.user)
        XCTAssertTrue(m.user.contains("Hand-picked text."))
        XCTAssertTrue(m.system.contains("highlighted by hand"), m.system)
        XCTAssertTrue(m.system.contains("Merge the marked passage and the text the user highlighted in “Original” evenly"), m.system)
        // Excerpts: the passage itself and blank ones are left out.
        XCTAssertEqual(spec.usableExcerpts, ["An extra bit."])
        XCTAssertTrue(m.user.contains("<highlighted_excerpt>\nAn extra bit.\n</highlighted_excerpt>"), m.user)
    }

    func testMatchedCounterpartKeepsTheLineMatchWording() {
        let doc = "Intro. The passage. Outro."
        let spec = SelectionRewriteSpec(documentText: doc, range: (doc as NSString).range(of: "The passage."),
                                        counterpart: "Old passage.", passageWeight: 0.5, instructions: "Humanize.")
        let m = SelectionRewrite.messages(for: spec)
        XCTAssertTrue(m.user.contains("that matches this passage:"))
        XCTAssertTrue(m.system.contains("cut along line boundaries"))
        XCTAssertFalse(m.user.contains("highlighted"))
    }
}
