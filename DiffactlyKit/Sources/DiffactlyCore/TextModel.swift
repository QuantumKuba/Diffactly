import Foundation

/// One side of the comparison split into lines.
struct SideText {
    /// Lines without their terminating `\n` (and without a trailing `\r`).
    var lines: [String]
    var hasTrailingNewline: Bool
    var usesCRLF: Bool

    init(_ text: String) {
        if text.isEmpty {
            lines = []
            hasTrailingNewline = false
            usesCRLF = false
            return
        }
        // Split on the scalar level: Swift treats "\r\n" as one Character, so a
        // Character-based split would never break CRLF lines.
        var parts = text.components(separatedBy: "\n")
        hasTrailingNewline = parts.count > 1 && parts.last == ""
        if hasTrailingNewline { parts.removeLast() }
        var crlf = false
        for i in parts.indices where parts[i].hasSuffix("\r") {
            parts[i].removeLast()
            crlf = true
        }
        lines = parts
        usesCRLF = crlf
    }

    var characterCount: Int { lines.reduce(0) { $0 + $1.count } }
}

/// Builds the comparison keys that implement the ignore options. Two pieces of
/// text compare equal when their keys are equal; the original text is always
/// kept for display.
struct Normalizer {
    let options: DiffOptions
    private let ignored: [String]

    private static let quoteCharacters: Set<Character> = ["'", "\"", "`", "´", "‘", "’", "‚", "‛", "“", "”", "„", "‟", "′", "″", "«", "»", "‹", "›"]
    private static let dashCharacters: Set<Character> = ["-", "‐", "‑", "‒", "–", "—", "―", "−", "﹘", "﹣", "－"]

    init(options: DiffOptions) {
        self.options = options
        let rules = options.ignoredStrings.filter { !$0.isEmpty }
        // Longest first so overlapping rules remove the most text.
        self.ignored = rules
            .map { options.ignoreCase ? $0.lowercased() : $0 }
            .sorted { $0.count > $1.count }
    }

    var hasIgnoreRules: Bool { !ignored.isEmpty }

    /// Case / quote / dash folding shared by every key.
    func fold(_ s: String) -> String {
        var out = options.ignoreCase ? s.lowercased() : s
        if options.ignoreQuotes || options.ignoreDashes {
            out = String(out.map { ch -> Character in
                if options.ignoreQuotes, Self.quoteCharacters.contains(ch) { return "\"" }
                if options.ignoreDashes, Self.dashCharacters.contains(ch) { return "-" }
                return ch
            })
        }
        return out
    }

    func removingIgnoredStrings(_ s: String) -> String {
        guard !ignored.isEmpty else { return s }
        var out = s
        for rule in ignored { out = out.replacingOccurrences(of: rule, with: "") }
        return out
    }

    /// Key used to align whole lines. Leading/trailing whitespace never prevents
    /// alignment (re-indented lines still line up); with `ignoreWhitespace` all
    /// whitespace is dropped.
    func lineKey(_ line: String) -> String {
        var s = removingIgnoredStrings(fold(line))
        if options.ignoreWhitespace {
            s.removeAll { $0.isWhitespace }
        } else {
            s = s.trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    /// Key used to decide whether a changed region is only an ignored difference.
    func contentKey(_ s: String) -> String {
        var out = removingIgnoredStrings(fold(s))
        if options.ignoreWhitespace { out.removeAll { $0.isWhitespace } }
        return out
    }

    /// Key for a single sub-line token.
    func tokenKey(_ token: String) -> String {
        if options.ignoreWhitespace, token.allSatisfy(\.isWhitespace) { return " " }
        return fold(token)
    }
}

enum Tokenizer {
    enum Kind { case word, space, symbol }

    static func kind(of ch: Character) -> Kind {
        if ch.isWhitespace { return .space }
        if ch.isLetter || ch.isNumber || ch == "_" { return .word }
        // Combining marks attach to the preceding grapheme already, so anything
        // else (punctuation, symbols, emoji) is a standalone token.
        return .symbol
    }

    /// Splits text into words, whitespace runs and individual symbols.
    static func words(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var currentKind: Kind? = nil
        for ch in text {
            let k = kind(of: ch)
            if k == .symbol {
                if !current.isEmpty { tokens.append(current); current = "" }
                tokens.append(String(ch))
                currentKind = nil
            } else if k == currentKind {
                current.append(ch)
            } else {
                if !current.isEmpty { tokens.append(current) }
                current = String(ch)
                currentKind = k
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func characters(_ text: String) -> [String] {
        text.map { String($0) }
    }

    /// Number of words (runs of letters/digits) in a string.
    static func wordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for ch in text {
            let w = kind(of: ch) == .word
            if w && !inWord { count += 1 }
            inWord = w
        }
        return count
    }
}

/// Character-bigram profile used for fast "how similar are these two lines" checks.
struct BigramProfile {
    let sorted: [UInt64]
    let length: Int
    let text: String

    init(_ s: String) {
        text = s
        let scalars = Array(s.unicodeScalars)
        length = scalars.count
        guard scalars.count >= 2 else { sorted = []; return }
        var codes: [UInt64] = []
        codes.reserveCapacity(scalars.count - 1)
        for i in 0..<(scalars.count - 1) {
            codes.append(UInt64(scalars[i].value) << 32 | UInt64(scalars[i + 1].value))
        }
        sorted = codes.sorted()
    }

    /// Sørensen–Dice coefficient over character bigrams, 0…1.
    func similarity(to other: BigramProfile) -> Double {
        if text == other.text { return 1 }
        if sorted.isEmpty || other.sorted.isEmpty {
            // One-character (or empty) strings: equal-or-not was handled above;
            // give partial credit for containment so "}" vs "};" still pairs.
            if length == 0 || other.length == 0 { return 0 }
            let short = length <= other.length ? text : other.text
            let long = length <= other.length ? other.text : text
            return long.contains(short) ? Double(short.count) / Double(long.count) : 0
        }
        var i = 0, j = 0, shared = 0
        let a = sorted, b = other.sorted
        while i < a.count && j < b.count {
            if a[i] == b[j] { shared += 1; i += 1; j += 1 }
            else if a[i] < b[j] { i += 1 }
            else { j += 1 }
        }
        return 2 * Double(shared) / Double(a.count + b.count)
    }
}
