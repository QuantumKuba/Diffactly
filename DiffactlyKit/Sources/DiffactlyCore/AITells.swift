import Foundation

/// Finds the words, phrases and habits that make text read as machine-written
/// ("delve", "a testament to", "not just X but Y", em-dash chains, …).
///
/// The catalogue is assembled from public write-ups of AI writing tells
/// (Wikipedia's "Signs of AI writing", open-source humanizer prompts and
/// slop-phrase lists). It is a heuristic: a hit is something worth a second
/// look, not proof that a model wrote the text.
public enum AITells {

    public enum Category: String, CaseIterable, Sendable, Codable {
        /// Single words models overuse ("delve", "tapestry", "pivotal").
        case vocabulary
        /// Stock phrases and openers ("in today's fast-paced world").
        case phrase
        /// Sentence shapes ("not just X, but Y", "it's not X — it's Y").
        case structure
        /// Chatbot residue ("I hope this helps", "As an AI").
        case chatbot

        public var title: String {
            switch self {
            case .vocabulary: return "Overused words"
            case .phrase: return "Stock phrases"
            case .structure: return "Formulaic structure"
            case .chatbot: return "Chatbot residue"
            }
        }
    }

    public struct Hit: Equatable, Sendable {
        /// The matched text exactly as it appears in the input.
        public var text: String
        public var category: Category
        /// UTF-16 range in the scanned text (matches NSTextView / NSString).
        public var range: NSRange
    }

    public struct Report: Equatable, Sendable {
        public var hits: [Hit]
        public var wordCount: Int
        /// Em dashes (—) in the text; a tell when dense, so counted separately.
        public var emDashes: Int
        /// Sentence-length coefficient of variation (σ / μ). Low values (< 0.32)
        /// indicate flat, uniform AI sentence cadence ("burstiness").
        public var burstinessCV: Double

        public init(
            hits: [Hit],
            wordCount: Int,
            emDashes: Int,
            burstinessCV: Double = 0
        ) {
            self.hits = hits
            self.wordCount = wordCount
            self.emDashes = emDashes
            self.burstinessCV = burstinessCV
        }

        /// True when the text is long enough to judge rhythm and sentence lengths
        /// are unnaturally uniform (a statistical AI cadence signature).
        public var hasUniformCadence: Bool {
            wordCount >= 60 && burstinessCV > 0 && burstinessCV < 0.32
        }

        /// Tells per 100 words, em dashes beyond one per 150 words included.
        public var density: Double {
            guard wordCount > 0 else { return 0 }
            let excessDashes = max(0, emDashes - wordCount / 150)
            return Double(hits.count + excessDashes) * 100 / Double(wordCount)
        }

        /// Distinct offending phrases (lower-cased), most frequent first.
        public var topPhrases: [(phrase: String, count: Int)] {
            var counts: [String: Int] = [:]
            for hit in hits { counts[hit.text.lowercased(), default: 0] += 1 }
            return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { ($0.key, $0.value) }
        }

        public var level: Level {
            switch density {
            case ..<0.75: return .low
            case ..<2.5: return .some
            default: return .high
            }
        }

        public static func == (a: Report, b: Report) -> Bool {
            a.hits == b.hits
                && a.wordCount == b.wordCount
                && a.emDashes == b.emDashes
        }
    }

    public enum Level: String, Sendable {
        case low, some, high
        public var title: String {
            switch self {
            case .low: return "Few AI tells"
            case .some: return "Some AI tells"
            case .high: return "Many AI tells"
            }
        }
    }

    // MARK: Catalogue

    /// Words that are fine on their own but that language models reach for far
    /// more often than people do. Matched as whole words, with common inflections.
    public static let vocabulary: [String] = [
        "delve", "delves", "delved", "delving",
        "tapestry", "testament", "pivotal", "paramount", "multifaceted",
        "intricate", "intricacies", "meticulous", "meticulously",
        "seamless", "seamlessly", "robust", "leverage", "leveraging",
        "harness", "harnessing", "unleash", "unlock", "unlocking",
        "elevate", "elevates", "empower", "empowering", "foster", "fostering",
        "bolster", "bolstering", "underscore", "underscores", "underscoring",
        "showcase", "showcasing", "navigate", "navigating", "embark", "embarking",
        "realm", "landscape", "ever-evolving", "ever-changing", "utilize", "utilizing",
        "facilitate", "facilitates", "streamline", "streamlined", "renowned", "breathtaking",
        "vibrant", "bustling", "nestled", "enigmatic", "captivating", "intriguing",
        "invaluable", "noteworthy", "commendable", "groundbreaking", "transformative",
        "cutting-edge", "game-changer", "game-changing", "holistic", "synergy",
        "resonate", "resonates", "interplay", "nuanced", "endeavor", "endeavour",
        "furthermore", "moreover", "additionally", "notably", "arguably",
        "crucial", "vital", "comprehensive", "garner", "garnered", "supercharge",
        "enduring", "profound", "beacon", "symphony", "boasts", "paradigm",
        "burgeoning", "cornerstone", "paragon", "crux", "reimagining",
        "spearhead", "spearheading", "catalyze", "catalyzing", "synergistic",
        "paradigmatic", "transcend", "transcending", "indelible",
    ]

    /// Stock phrases. Lower-case; matched case-insensitively on word boundaries.
    public static let phrases: [String] = [
        "in today's fast-paced world", "in today's digital age", "in today's world",
        "in the ever-evolving", "in the realm of", "in the world of",
        "it is important to note", "it's important to note", "it is worth noting",
        "it's worth noting", "it should be noted", "it is crucial to",
        "plays a crucial role", "plays a vital role", "plays a pivotal role",
        "plays a significant role", "a testament to", "stands as a testament",
        "serves as a testament", "a rich tapestry", "the intricate tapestry",
        "a myriad of", "a plethora of", "a wide range of", "a wide array of",
        "navigate the complexities", "the complexities of", "delve into", "dive into",
        "deep dive", "at its core", "at the heart of", "when it comes to",
        "in conclusion", "in summary", "to sum up", "overall,", "ultimately,",
        "in essence", "all in all", "first and foremost", "last but not least",
        "whether you're", "whether you are", "look no further",
        "unlock the potential", "unlock the power", "harness the power",
        "the power of", "pave the way", "paving the way", "shed light on",
        "sheds light on", "a key role", "key takeaways", "the bottom line",
        "game changer", "stay ahead of the curve", "ever-evolving landscape",
        "evolving landscape", "fast-paced", "seamless integration",
        "not only", "embark on a journey", "journey of", "elevate your",
        "valuable insights", "actionable insights", "a deeper understanding",
        "fostering a sense of", "a sense of community", "nestled in",
        "boasts a", "rich history", "rich cultural heritage", "enduring legacy",
        "left an indelible mark", "indelible mark", "captivated audiences",
        "remains to be seen", "only time will tell", "the future looks bright",
        "exciting times", "aligns with", "resonates with", "at the end of the day",
        "in the age of", "the reality is", "let's dive in", "let's break this down",
        "here's what you need to know", "the real question is", "what really matters",
        "despite these challenges", "marks a pivotal moment", "setting the stage for",
        "reflects a broader", "let that sink in", "experts argue", "paradigm shift",
        "let's explore", "here's a breakdown", "dive deeper", "worth mentioning",
        "it bears mentioning", "cannot be overstated", "can't be overstated",
        "broadly speaking", "by and large", "stands out as", "serves as a reminder",
        "underscores the importance", "highlights the importance", "moving forward",
        "going forward", "on the flip side", "that being said", "with that in mind",
        "at this juncture",
    ]

    /// Chatbot residue that should never survive into finished prose.
    public static let chatbotPhrases: [String] = [
        "as an ai", "as a language model", "as an ai language model",
        "i hope this helps", "hope this helps", "let me know if you",
        "feel free to", "certainly!", "absolutely!", "great question",
        "i'd be happy to", "i would be happy to", "here is the rewritten",
        "here's the rewritten", "rewritten version", "revised version",
        "as of my last", "as of my knowledge", "knowledge cutoff",
        "based on available information", "here's a draft", "here is a draft",
        "would you like me to", "happy to adjust", "happy to refine",
    ]

    /// Sentence shapes, as regular expressions (case-insensitive).
    public static let structures: [String] = [
        // "not just X, but (also) Y" / "not only X but also Y"
        #"\bnot (?:just|only|merely|simply) [^.!?;]{1,60}?,? but(?: also)?\b"#,
        // "it's not X — it's Y" / "this isn't X, it's Y"
        #"\b(?:it|this|that)(?:'s| is|’s) not [^.!?]{1,60}?[,;—–-]+ ?(?:it|this|that)(?:'s| is|’s)\b"#,
        #"\b(?:it|this|that) (?:isn't|isn’t) [^.!?]{1,60}?[,;—–-]+ ?(?:it|this|that)(?:'s| is|’s)\b"#,
        // "No X. No Y. Just Z." staccato
        #"\bno [a-z]+\. no [a-z]+\.(?: just\b)?"#,
        // "From X to Y," sweeping openers
        #"(?:^|[.!?]\s+)from [^,.]{1,40} to [^,.]{1,40},"#,
        // "Here's the thing:" / "The result?" style hooks
        #"\bhere's the (?:thing|kicker|catch)\b"#,
        #"\bthe (?:result|answer|kicker|catch)\?"#,
        // Participial -ing tail closers (", highlighting its importance.")
        #",\s+(?:highlighting|underscoring|showcasing|demonstrating|illustrating|reflecting|fostering|ensuring|paving|cementing)\b[^.!?]{0,70}[.!?]"#,
    ]

    // MARK: Scanning

    private struct Compiled: @unchecked Sendable {
        let patterns: [(NSRegularExpression, Category)]
    }

    private static let compiled: Compiled = {
        func alternation(_ items: [String]) -> String {
            items.sorted { $0.count > $1.count }
                .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: "'", with: "['’]") }
                .joined(separator: "|")
        }
        // Word boundaries that also respect hyphens ("well-robust" shouldn't hit).
        func wrap(_ body: String) -> String { #"(?<![\p{L}\p{N}-])(?:"# + body + #")(?![\p{L}\p{N}-])"# }
        // Phrases ending in punctuation can't use a trailing word boundary.
        func wrapPhrase(_ body: String) -> String { #"(?<![\p{L}\p{N}-])(?:"# + body + ")" }
        var list: [(NSRegularExpression, Category)] = []
        let opts: NSRegularExpression.Options = [.caseInsensitive]
        if let re = try? NSRegularExpression(pattern: wrapPhrase(alternation(chatbotPhrases)), options: opts) { list.append((re, .chatbot)) }
        if let re = try? NSRegularExpression(pattern: wrapPhrase(alternation(phrases)), options: opts) { list.append((re, .phrase)) }
        if let re = try? NSRegularExpression(pattern: wrap(alternation(vocabulary)), options: opts) { list.append((re, .vocabulary)) }
        for pattern in structures {
            if let re = try? NSRegularExpression(pattern: pattern, options: opts.union(.anchorsMatchLines)) { list.append((re, .structure)) }
        }
        return Compiled(patterns: list)
    }()

    /// Scans `text` for tells. Overlapping matches keep the earliest-listed
    /// category (chatbot > phrase > vocabulary > structure), so "delve into"
    /// counts once as a phrase rather than also as the word "delve".
    public static func scan(_ text: String) -> Report {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var taken = IndexSet()
        var hits: [Hit] = []
        for (re, category) in compiled.patterns {
            for match in re.matches(in: text, range: full) {
                let r = match.range
                guard r.length > 0 else { continue }
                let span = r.location..<(r.location + r.length)
                if taken.intersects(integersIn: span) { continue }
                taken.insert(integersIn: span)
                var matched = ns.substring(with: r)
                // Drop the sentence-boundary prefix captured by some structures.
                if category == .structure {
                    let trimmed = matched.drop { !$0.isLetter }
                    matched = String(trimmed)
                }
                hits.append(Hit(text: matched, category: category, range: r))
            }
        }
        hits.sort { $0.range.location < $1.range.location }
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        let dashes = text.reduce(0) { $0 + ($1 == "—" ? 1 : 0) } + latexEmDashCount(text)
        let burstiness = sentenceBurstinessCV(text)
        return Report(
            hits: hits,
            wordCount: words,
            emDashes: dashes,
            burstinessCV: burstiness
        )
    }

    private static let latexEmDash = try? NSRegularExpression(pattern: #"(?<=[\p{L}\p{N}\s}.,)])---(?=[\p{L}\p{N}\s{\\])"#)

    /// LaTeX writes an em dash as `---`; rules like `%-----` aren't counted.
    static func latexEmDashCount(_ text: String) -> Int {
        guard text.contains("---"), let re = latexEmDash else { return 0 }
        return re.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    // MARK: - Cadence & Number Preservation

    private static let sentenceSplitRegex = try? NSRegularExpression(pattern: #"[.!?]+(?:\s+|$)"#)
    private static let wordTokenRegex = try? NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#)

    /// Coefficient of variation (σ / μ) of sentence word lengths.
    /// Human writing typically mixes short and long sentences (CV ≥ 0.40);
    /// unedited LLM output often clusters around a uniform sentence length (CV < 0.32).
    public static func sentenceBurstinessCV(_ text: String) -> Double {
        let ns = text as NSString
        guard ns.length > 0, let re = sentenceSplitRegex else { return 0 }
        let full = NSRange(location: 0, length: ns.length)
        var sentences: [String] = []
        var start = 0
        for m in re.matches(in: text, range: full) {
            let chunk = ns.substring(with: NSRange(location: start, length: m.range.location - start))
            sentences.append(chunk)
            start = NSMaxRange(m.range)
        }
        if start < ns.length {
            sentences.append(ns.substring(from: start))
        }
        let lengths = sentences.compactMap { s -> Double? in
            let count = wordTokens(s).count
            return count >= 2 ? Double(count) : nil
        }
        guard lengths.count >= 3 else { return 0 }
        let mean = lengths.reduce(0, +) / Double(lengths.count)
        guard mean > 0 else { return 0 }
        let variance = lengths.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(lengths.count)
        return variance.squareRoot() / mean
    }

    private static func wordTokens(_ text: String) -> [String] {
        guard let re = wordTokenRegex else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).lowercased()
        }
    }

    private static let nonProseStripRegex = try? NSRegularExpression(
        pattern: #"https?://\S+|\\(?:cite|citep|citet|ref|eqref|autoref|label|usepackage)\{[^{}]*\}|(?m)^[ \t]*\d{1,2}[.)][ \t]+"#
    )
    private static let numberTokenRegex = try? NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_\\])[$€£¥]?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?%?(?![\p{L}\p{N}_])"#
    )

    /// Extracts factual numbers from `text` in order of appearance (excluding URLs,
    /// LaTeX citation/ref keys, and line-leading list numbering).
    public static func extractNumbers(_ text: String) -> [String] {
        let cleaned = stripNonProseNumericContexts(text)
        guard let re = numberTokenRegex else { return [] }
        let ns = cleaned as NSString
        return re.matches(in: cleaned, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range)
        }
    }

    /// Returns any numbers from `source` that were dropped or altered in `target`.
    /// Formatting differences in grouping commas or currency/percent symbols
    /// (e.g. `$1,200` vs `1200` or `61.3%` vs `61.3 percent`) are accepted as matching;
    /// changed digits or rounded values (e.g. `61.3%` → `61%`) are flagged.
    public static func missingNumbers(from source: String, in target: String) -> [String] {
        let sourceTokens = extractNumbers(source)
        guard !sourceTokens.isEmpty else { return [] }
        let targetCanonical = Set(extractNumbers(target).map(canonicalNumber))
        var missing: [String] = []
        var seenCanonical = Set<String>()
        for token in sourceTokens {
            let canon = canonicalNumber(token)
            guard !canon.isEmpty, !seenCanonical.contains(canon) else { continue }
            if !targetCanonical.contains(canon) {
                missing.append(token)
                seenCanonical.insert(canon)
            }
        }
        return missing
    }

    private static func stripNonProseNumericContexts(_ text: String) -> String {
        guard let re = nonProseStripRegex else { return text }
        let ns = text as NSString
        return re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
    }

    private static func canonicalNumber(_ token: String) -> String {
        var s = token.filter { $0.isNumber || $0 == "." }
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    /// Verification metrics comparing a rewrite result against its source.
    public struct Verification: Equatable, Sendable {
        /// Total distinct factual numbers present in the source text.
        public var sourceNumberCount: Int
        /// Numbers from the source that are missing or altered in the result.
        public var missingNumbers: [String]
        /// Sentence-length coefficient of variation (σ / μ) of the result.
        public var burstinessCV: Double

        public var allNumbersPreserved: Bool { missingNumbers.isEmpty }
    }

    public static func verify(source: String, result: String) -> Verification {
        let distinctSourceNumbers = Set(extractNumbers(source).map(canonicalNumber)).filter { !$0.isEmpty }.count
        return Verification(
            sourceNumberCount: distinctSourceNumbers,
            missingNumbers: missingNumbers(from: source, in: result),
            burstinessCV: sentenceBurstinessCV(result)
        )
    }
}
