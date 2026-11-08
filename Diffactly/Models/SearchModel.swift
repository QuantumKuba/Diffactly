import SwiftUI
import AppKit
import DiffactlyCore

enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    case both = "both"
    case left = "left"
    case right = "right"

    var id: String { rawValue }

    @MainActor
    func title(in document: DiffDocument?) -> String {
        switch self {
        case .both:
            return "All"
        case .left:
            return document?.title(for: .left) ?? "Original"
        case .right:
            return document?.title(for: .right) ?? "Changed"
        }
    }
}

struct SearchMatch: Identifiable, Equatable, Sendable {
    let id: UUID
    var side: DiffDocument.Side
    /// 1-based line number in that side's text.
    var line: Int
    /// Full document UTF-16 character range.
    var range: NSRange
    /// UTF-16 character range within the line.
    var lineRange: NSRange
    /// Corresponding diff row ID in `result.rows` if applicable.
    var rowID: Int?

    init(
        id: UUID = UUID(),
        side: DiffDocument.Side,
        line: Int,
        range: NSRange,
        lineRange: NSRange? = nil,
        rowID: Int? = nil
    ) {
        self.id = id
        self.side = side
        self.line = line
        self.range = range
        self.lineRange = lineRange ?? range
        self.rowID = rowID
    }
}

@MainActor
final class SearchModel: ObservableObject {
    weak var document: DiffDocument?

    @Published var isPresented: Bool = false
    @Published var query: String = "" {
        didSet {
            if query != oldValue { performSearch() }
        }
    }
    @Published var scope: SearchScope = .both {
        didSet {
            if scope != oldValue { performSearch() }
        }
    }
    @Published var caseSensitive: Bool = false {
        didSet {
            if caseSensitive != oldValue { performSearch() }
        }
    }
    @Published var wholeWord: Bool = false {
        didSet {
            if wholeWord != oldValue { performSearch() }
        }
    }
    @Published var useRegex: Bool = false {
        didSet {
            if useRegex != oldValue { performSearch() }
        }
    }
    @Published var activeSide: DiffDocument.Side?

    @Published private(set) var matches: [SearchMatch] = []
    @Published var currentMatchIndex: Int? {
        didSet {
            if let idx = currentMatchIndex, matches.indices.contains(idx) {
                scrollToMatchID = matches[idx].id
            } else {
                scrollToMatchID = nil
            }
        }
    }
    @Published private(set) var scrollToMatchID: UUID?
    @Published private(set) var regexError: String?

    /// Fast lookup by side and line: [side: [line: [SearchMatch]]]
    @Published private(set) var matchesBySideAndLine: [DiffDocument.Side: [Int: [SearchMatch]]] = [.left: [:], .right: [:]]

    init(document: DiffDocument? = nil) {
        self.document = document
    }

    var currentMatch: SearchMatch? {
        guard let idx = currentMatchIndex, matches.indices.contains(idx) else { return nil }
        return matches[idx]
    }

    var matchSummary: String {
        guard !query.isEmpty else { return "" }
        if regexError != nil { return "Invalid regex" }
        guard !matches.isEmpty else { return "No matches" }
        let current = (currentMatchIndex.map { $0 + 1 } ?? 0)
        return "\(current) of \(matches.count)"
    }

    func matches(for side: DiffDocument.Side, line: Int) -> [SearchMatch] {
        matchesBySideAndLine[side]?[line] ?? []
    }

    func performSearch() {
        regexError = nil
        guard !query.isEmpty, let document else {
            matches = []
            matchesBySideAndLine = [.left: [:], .right: [:]]
            currentMatchIndex = nil
            return
        }

        let leftText = document.leftText
        let rightText = document.rightText
        let result = document.result

        var newMatches: [SearchMatch] = []
        var caughtRegexError: String? = nil

        if scope == .left || scope == .both {
            let (m, err) = Self.findMatches(
                in: leftText,
                side: .left,
                query: query,
                caseSensitive: caseSensitive,
                wholeWord: wholeWord,
                useRegex: useRegex,
                result: result
            )
            newMatches.append(contentsOf: m)
            if let err { caughtRegexError = err }
        }

        if scope == .right || scope == .both {
            let (m, err) = Self.findMatches(
                in: rightText,
                side: .right,
                query: query,
                caseSensitive: caseSensitive,
                wholeWord: wholeWord,
                useRegex: useRegex,
                result: result
            )
            newMatches.append(contentsOf: m)
            if let err { caughtRegexError = err }
        }

        self.regexError = caughtRegexError
        self.matches = newMatches

        var bySideAndLine: [DiffDocument.Side: [Int: [SearchMatch]]] = [.left: [:], .right: [:]]
        for match in newMatches {
            bySideAndLine[match.side, default: [:]][match.line, default: []].append(match)
        }
        self.matchesBySideAndLine = bySideAndLine

        if newMatches.isEmpty {
            currentMatchIndex = nil
        } else if let current = currentMatchIndex, current < newMatches.count {
            currentMatchIndex = current
        } else {
            currentMatchIndex = 0
        }
    }

    func updateRowIDs(with result: DiffResult) {
        guard !matches.isEmpty else { return }
        var leftRowByLine: [Int: Int] = [:]
        var rightRowByLine: [Int: Int] = [:]
        for row in result.rows {
            if let l = row.left?.number { leftRowByLine[l] = row.id }
            if let r = row.right?.number { rightRowByLine[r] = row.id }
        }
        for i in matches.indices {
            let line = matches[i].line
            matches[i].rowID = (matches[i].side == .left ? leftRowByLine[line] : rightRowByLine[line])
        }
        var bySideAndLine: [DiffDocument.Side: [Int: [SearchMatch]]] = [.left: [:], .right: [:]]
        for match in matches {
            bySideAndLine[match.side, default: [:]][match.line, default: []].append(match)
        }
        self.matchesBySideAndLine = bySideAndLine
    }

    func findNext() {
        guard !matches.isEmpty else {
            currentMatchIndex = nil
            return
        }
        if let current = currentMatchIndex {
            currentMatchIndex = (current + 1) % matches.count
        } else {
            currentMatchIndex = 0
        }
    }

    func findPrevious() {
        guard !matches.isEmpty else {
            currentMatchIndex = nil
            return
        }
        if let current = currentMatchIndex {
            currentMatchIndex = (current - 1 + matches.count) % matches.count
        } else {
            currentMatchIndex = matches.count - 1
        }
    }

    func openSearch(focusedSide: DiffDocument.Side? = nil) {
        let side = focusedSide ?? activeSide
        if let side {
            scope = (side == .left ? .left : .right)
        }
        isPresented = true
        performSearch()
        if currentMatchIndex == nil, !matches.isEmpty {
            currentMatchIndex = 0
        }
    }

    func closeSearch() {
        isPresented = false
        currentMatchIndex = nil
    }

    func useSelectionForSearch() {
        guard let document else { return }
        var textToSearch = document.selection?.text ?? ""
        if textToSearch.isEmpty {
            textToSearch = NSPasteboard(name: .find).string(forType: .string) ?? ""
        }
        if !textToSearch.isEmpty {
            query = textToSearch
            NSPasteboard(name: .find).clearContents()
            NSPasteboard(name: .find).setString(textToSearch, forType: .string)
        }
        openSearch(focusedSide: document.selection?.side)
    }

    // MARK: - Matching Helper

    static func findMatches(
        in text: String,
        side: DiffDocument.Side,
        query: String,
        caseSensitive: Bool,
        wholeWord: Bool,
        useRegex: Bool,
        result: DiffResult?
    ) -> (matches: [SearchMatch], error: String?) {
        guard !text.isEmpty, !query.isEmpty else { return ([], nil) }

        let nsString = text as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        var rawRanges: [NSRange] = []

        if useRegex {
            var options: NSRegularExpression.Options = []
            if !caseSensitive {
                options.insert(.caseInsensitive)
            }
            let pattern: String
            if wholeWord {
                pattern = "\\b(?:\(query))\\b"
            } else {
                pattern = query
            }
            let regex: NSRegularExpression
            do {
                regex = try NSRegularExpression(pattern: pattern, options: options)
            } catch {
                return ([], error.localizedDescription)
            }
            let checkingResults = regex.matches(in: text, options: [], range: fullRange)
            rawRanges = checkingResults.map(\.range).filter { $0.length > 0 }
        } else {
            var searchOptions: NSString.CompareOptions = [.literal]
            if !caseSensitive {
                searchOptions.insert(.caseInsensitive)
            }
            let queryStartsWord = query.utf16.first.map(isWordCodeUnit) ?? false
            let queryEndsWord = query.utf16.last.map(isWordCodeUnit) ?? false

            var searchRange = fullRange
            while searchRange.location < nsString.length {
                let found = nsString.range(of: query, options: searchOptions, range: searchRange)
                guard found.location != NSNotFound else { break }

                var isMatch = true
                if wholeWord {
                    if queryStartsWord && found.location > 0 {
                        let prevChar = nsString.character(at: found.location - 1)
                        if isWordCodeUnit(prevChar) {
                            isMatch = false
                        }
                    }
                    if queryEndsWord {
                        let end = NSMaxRange(found)
                        if end < nsString.length {
                            let nextChar = nsString.character(at: end)
                            if isWordCodeUnit(nextChar) {
                                isMatch = false
                            }
                        }
                    }
                }

                if isMatch && found.length > 0 {
                    rawRanges.append(found)
                }

                let nextStart = found.location + max(found.length, 1)
                if nextStart >= nsString.length { break }
                searchRange = NSRange(location: nextStart, length: nsString.length - nextStart)
            }
        }

        var lineStarts: [Int] = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 10 { lineStarts.append(offset) }
        }

        var rowByLine: [Int: Int] = [:]
        if let rows = result?.rows {
            for row in rows {
                if let lineNum = (side == .left ? row.left?.number : row.right?.number) {
                    rowByLine[lineNum] = row.id
                }
            }
        }

        let matches = rawRanges.map { r -> SearchMatch in
            let line = lineNumber(at: r.location, lineStarts: lineStarts)
            let lineStart = lineStarts[line - 1]
            let lineRange = NSRange(location: r.location - lineStart, length: r.length)
            let rowID = rowByLine[line]
            return SearchMatch(side: side, line: line, range: r, lineRange: lineRange, rowID: rowID)
        }
        return (matches, nil)
    }

    static func isWordCodeUnit(_ unit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }

    static func lineNumber(at location: Int, lineStarts: [Int]) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= location {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo + 1
    }
}
