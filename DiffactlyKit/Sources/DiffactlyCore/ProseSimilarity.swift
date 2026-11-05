import Foundation

/// Content-word similarity for prose (paragraph-per-line text such as LaTeX or
/// Markdown).
///
/// Character bigrams can't tell a reworded paragraph from an unrelated one on the
/// same topic: both share most letter pairs. Here a line becomes a vector of
/// stemmed content words (stopwords dropped) weighted by how rare each word is
/// across both documents, compared by cosine. Distinctive vocabulary — citation
/// keys, technical terms — carries a rewritten paragraph back to its original;
/// shared filler doesn't.
struct ProseIndex {
    /// Lines with fewer words than this are not treated as prose.
    static let minWords = 12
    /// Minimum similarity for two prose lines to count as the same paragraph.
    static let pairThreshold = 0.3

    private var profiles: [Side: [Int: Profile]] = [.left: [:], .right: [:]]

    enum Side { case left, right }

    struct Profile {
        /// (term id, weight), sorted by term id.
        let terms: [(Int, Double)]
        let norm: Double
    }

    /// Builds profiles for every prose line of both sides; IDF comes from all of them.
    init(left: [String], right: [String]) {
        var vocabulary: [String: Int] = [:]
        var termLists: [(Side, Int, [Int])] = []
        for (side, lines) in [(Side.left, left), (Side.right, right)] {
            for (i, line) in lines.enumerated() {
                guard Tokenizer.wordCount(line) >= Self.minWords else { continue }
                let ids = Self.contentWords(line).map { word -> Int in
                    if let id = vocabulary[word] { return id }
                    vocabulary[word] = vocabulary.count
                    return vocabulary.count - 1
                }
                if ids.count >= 4 { termLists.append((side, i, ids)) }
            }
        }
        var documentFrequency = [Int](repeating: 0, count: vocabulary.count)
        for (_, _, ids) in termLists { for id in Set(ids) { documentFrequency[id] += 1 } }
        let n = Double(termLists.count)
        for (side, i, ids) in termLists {
            var counts: [Int: Int] = [:]
            for id in ids { counts[id, default: 0] += 1 }
            let terms = counts.map { id, c in (id, (1 + log(Double(c))) * log(1 + n / Double(documentFrequency[id]))) }
                .sorted { $0.0 < $1.0 }
            let norm = sqrt(terms.reduce(0) { $0 + $1.1 * $1.1 })
            profiles[side]![i] = Profile(terms: terms, norm: norm)
        }
    }

    /// Whether a (0-based) line on a side is prose.
    func isProse(_ side: Side, _ index: Int) -> Bool { profiles[side]![index] != nil }

    /// Cosine similarity of two prose lines, or nil when either isn't prose.
    func similarity(left i: Int, right j: Int) -> Double? {
        guard let a = profiles[.left]![i], let b = profiles[.right]![j] else { return nil }
        return Self.cosine(a, b)
    }

    static func cosine(_ a: Profile, _ b: Profile) -> Double {
        guard a.norm > 0, b.norm > 0 else { return 0 }
        var i = 0, j = 0, dot = 0.0
        while i < a.terms.count && j < b.terms.count {
            let x = a.terms[i], y = b.terms[j]
            if x.0 == y.0 { dot += x.1 * y.1; i += 1; j += 1 }
            else if x.0 < y.0 { i += 1 }
            else { j += 1 }
        }
        return dot / (a.norm * b.norm)
    }

    // MARK: Words

    static func contentWords(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        func flush() {
            if current.count > 1, !stopwords.contains(current) { out.append(stem(current)) }
            current = ""
        }
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber { current.append(ch) } else { flush() }
        }
        flush()
        return out
    }

    /// Very light suffix stripping: enough to join "conflict"/"conflicts" or
    /// "deferring"/"deferred" without a dictionary.
    static func stem(_ word: String) -> String {
        for suffix in ["ations", "ation", "ings", "ing", "edly", "ed", "es", "s", "ly"]
        where word.hasSuffix(suffix) && word.count - suffix.count >= 4 {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    static let stopwords: Set<String> = [
        "a", "an", "the", "of", "to", "in", "on", "for", "and", "or", "but", "is", "are", "was", "were",
        "be", "been", "it", "its", "that", "this", "these", "those", "with", "as", "by", "at", "from",
        "which", "who", "whom", "whether", "what", "where", "when", "while", "not", "no", "has", "have",
        "had", "do", "does", "than", "then", "so", "such", "into", "through", "between", "we", "our",
        "they", "their", "them", "there", "can", "could", "would", "should", "may", "might", "will",
        "also", "more", "most", "one", "other", "only", "both", "each", "any", "all", "how", "about",
        "over", "under", "same", "very", "if", "he", "she", "his", "her", "you", "your", "i", "my",
    ]
}
