import Foundation

/// Word, character and line totals for a piece of text (a whole side of the
/// comparison, or the part of it the user has selected).
///
/// A *word* is a run of non-whitespace characters, like `wc -w` and most word
/// processors count them: `don't`, `stop-gap` and `3.14` are one word each.
/// Text without spaces (e.g. Chinese or Japanese) therefore counts per run, not
/// per word.
public struct TextCounts: Equatable, Sendable {
    public var words: Int
    /// Grapheme clusters, line breaks included (`"\r\n"` and `"👋🏽"` count once).
    public var characters: Int
    /// Lines the way the diff sees them: a final line break does not start a new line.
    public var lines: Int

    public static let zero = TextCounts(words: 0, characters: 0, lines: 0)

    public init(words: Int, characters: Int, lines: Int) {
        self.words = words
        self.characters = characters
        self.lines = lines
    }

    public init(_ text: String) {
        var words = 0
        var newlines = 0
        var inWord = false
        var last: Unicode.Scalar?
        // Scalar level on purpose: Swift fuses "\r\n" into one Character, which
        // would hide the line break from a Character-based scan.
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                words += 1
            }
            if scalar == "\n" { newlines += 1 }
            last = scalar
        }
        self.words = words
        self.characters = text.count
        self.lines = last == nil ? 0 : newlines + (last == "\n" ? 0 : 1)
    }
}
