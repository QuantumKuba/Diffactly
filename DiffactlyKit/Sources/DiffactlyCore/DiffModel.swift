import Foundation

// MARK: - Options

/// How finely changes inside a modified line are reported.
public enum DiffLevel: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Word diff, refined to characters where a word was only lightly edited
    /// (`colour` → `color` highlights one letter, `quick` → `fast` the whole word).
    case smart
    /// Whole words / punctuation / whitespace runs.
    case word
    /// Individual characters (grapheme clusters, so emoji never split).
    case character

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .smart: return "Smart"
        case .word: return "Word"
        case .character: return "Character"
        }
    }
}

/// Everything that influences how two texts are compared.
public struct DiffOptions: Codable, Sendable, Equatable {
    public var level: DiffLevel
    /// Treat lines that differ only in whitespace as unchanged and never
    /// highlight whitespace-only edits.
    public var ignoreWhitespace: Bool
    public var ignoreCase: Bool
    /// Treat straight and curly quotes (and backticks) as the same character.
    public var ignoreQuotes: Bool
    /// Treat hyphen, en dash, em dash and minus as the same character.
    public var ignoreDashes: Bool
    /// Substrings whose presence or absence should never count as a change.
    public var ignoredStrings: [String]
    /// Detect blocks of lines that were moved rather than deleted and re-added.
    public var detectMoves: Bool

    public init(
        level: DiffLevel = .smart,
        ignoreWhitespace: Bool = false,
        ignoreCase: Bool = false,
        ignoreQuotes: Bool = false,
        ignoreDashes: Bool = false,
        ignoredStrings: [String] = [],
        detectMoves: Bool = true
    ) {
        self.level = level
        self.ignoreWhitespace = ignoreWhitespace
        self.ignoreCase = ignoreCase
        self.ignoreQuotes = ignoreQuotes
        self.ignoreDashes = ignoreDashes
        self.ignoredStrings = ignoredStrings
        self.detectMoves = detectMoves
    }
}

// MARK: - Result

public enum RowKind: String, Codable, Sendable {
    /// Same line on both sides (possibly differing only in ignored content).
    case unchanged
    /// A line that exists on both sides with edits inside it.
    case modified
    /// Only on the left (original) side.
    case removed
    /// Only on the right (changed) side.
    case added
}

/// A run of text inside a line. Segments of a line concatenate to the full line text.
public struct DiffSegment: Codable, Sendable, Equatable {
    public var text: String
    public var isChanged: Bool

    public init(_ text: String, changed: Bool) {
        self.text = text
        self.isChanged = changed
    }
}

/// One side of a row.
public struct DiffLine: Codable, Sendable, Equatable {
    /// 1-based line number in that side's text.
    public var number: Int
    public var text: String
    public var segments: [DiffSegment]

    public init(number: Int, text: String, segments: [DiffSegment]) {
        self.number = number
        self.text = text
        self.segments = segments
    }

    public var hasChangedSegments: Bool { segments.contains { $0.isChanged } }
}

/// One aligned row of the comparison. `left` is nil for additions, `right` for removals.
public struct DiffRow: Codable, Sendable, Identifiable, Equatable {
    public var id: Int
    public var kind: RowKind
    public var left: DiffLine?
    public var right: DiffLine?
    /// Set when this removed/added line belongs to a detected move.
    public var moveID: Int?
    /// True when the two sides differ only in content the options say to ignore.
    public var hasIgnoredDifferences: Bool

    public var isChange: Bool { kind != .unchanged }
}

/// A contiguous run of changed rows.
public struct DiffHunk: Codable, Sendable, Identifiable, Equatable {
    public var id: Int
    /// Indices into `DiffResult.rows` (half-open).
    public var rowRange: Range<Int>
    public var leftLines: ClosedRange<Int>?
    public var rightLines: ClosedRange<Int>?
}

/// A block of lines that was deleted in one place and inserted in another.
public struct DiffMove: Codable, Sendable, Identifiable, Equatable {
    public var id: Int
    /// Line numbers on the left side where the block came from.
    public var from: ClosedRange<Int>
    /// Line numbers on the right side where it went.
    public var to: ClosedRange<Int>
    /// 1.0 for an exact move, lower for a moved-and-edited block.
    public var similarity: Double
}

/// A paragraph whose content went into a line shown elsewhere — the other half
/// of a split or merge (e.g. two paragraphs rewritten into one). Unlike a move,
/// neither line is "the same line"; they share distinctive content.
public struct DiffRelation: Codable, Sendable, Identifiable, Equatable {
    public var id: Int
    /// Line number on the left side.
    public var left: Int
    /// Line number on the right side.
    public var right: Int
    /// Content-word similarity, 0…1.
    public var similarity: Double
}

public struct DiffStats: Codable, Sendable, Equatable {
    public var unchangedLines = 0
    public var modifiedLines = 0
    public var removedLines = 0
    public var addedLines = 0
    public var movedLines = 0

    public var removedWords = 0
    public var addedWords = 0
    public var removedCharacters = 0
    public var addedCharacters = 0

    public var leftLineCount = 0
    public var rightLineCount = 0
    /// Share of characters both texts have in common, 0…1.
    public var similarity = 1.0
    public var lineEndingsDiffer = false
    public var trailingNewlineDiffers = false

    /// Lines on the left that are gone or edited (Diffchecker-style "removals").
    public var removals: Int { removedLines + modifiedLines }
    /// Lines on the right that are new or edited ("additions").
    public var additions: Int { addedLines + modifiedLines }
}

public struct DiffResult: Codable, Sendable, Equatable {
    public var rows: [DiffRow]
    public var hunks: [DiffHunk]
    public var moves: [DiffMove]
    /// Split/merge links between paragraphs (see `DiffRelation`).
    public var relations: [DiffRelation]
    public var stats: DiffStats
    public var options: DiffOptions
    public var leftHasTrailingNewline: Bool
    public var rightHasTrailingNewline: Bool

    /// No visible differences (ignored differences don't count).
    public var isIdentical: Bool { hunks.isEmpty }

    public static let empty = DiffResult(
        rows: [], hunks: [], moves: [], relations: [], stats: DiffStats(), options: DiffOptions(),
        leftHasTrailingNewline: false, rightHasTrailingNewline: false
    )

    public func move(id: Int?) -> DiffMove? {
        guard let id else { return nil }
        return moves.first { $0.id == id }
    }
}
