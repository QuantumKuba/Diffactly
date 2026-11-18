import SwiftUI
import AppKit
import DiffactlyCore

/// One place for every diff colour, shared by the editors, the output view and the charts.
enum DiffPalette {
    static let removedNS = NSColor.systemRed
    static let addedNS = NSColor.systemGreen
    static let modifiedNS = NSColor.systemOrange
    static let movedNS = NSColor.systemPurple
    /// Split/merge links between paragraphs.
    static let relatedNS = NSColor.systemTeal

    static var removed: Color { Color(nsColor: removedNS) }
    static var added: Color { Color(nsColor: addedNS) }
    static var modified: Color { Color(nsColor: modifiedNS) }
    static var moved: Color { Color(nsColor: movedNS) }
    static var related: Color { Color(nsColor: relatedNS) }
    static var unchanged: Color { Color.secondary.opacity(0.35) }

    /// Dark mode needs slightly stronger tints to read against dark backgrounds.
    private static func isDark(_ appearance: NSAppearance?) -> Bool {
        (appearance ?? NSApp.effectiveAppearance).bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func lineTint(_ style: EditorHighlights.Style, appearance: NSAppearance? = nil) -> NSColor {
        let dark = isDark(appearance)
        switch style {
        case .removed: return removedNS.withAlphaComponent(dark ? 0.20 : 0.12)
        case .added: return addedNS.withAlphaComponent(dark ? 0.20 : 0.12)
        case .modified: return modifiedNS.withAlphaComponent(dark ? 0.13 : 0.08)
        case .moved: return movedNS.withAlphaComponent(dark ? 0.20 : 0.11)
        }
    }

    static func wordTint(_ style: EditorHighlights.Style, appearance: NSAppearance? = nil) -> NSColor {
        let dark = isDark(appearance)
        switch style {
        case .removed: return removedNS.withAlphaComponent(dark ? 0.45 : 0.30)
        case .added: return addedNS.withAlphaComponent(dark ? 0.45 : 0.30)
        case .modified: return modifiedNS.withAlphaComponent(dark ? 0.45 : 0.30)
        case .moved: return movedNS.withAlphaComponent(dark ? 0.45 : 0.28)
        }
    }

    /// Pending AI suggestions (indigo, so they don't read as a diff change).
    static let suggestionNS = NSColor.systemIndigo
    static var suggestion: Color { Color(nsColor: suggestionNS) }

    static func suggestionTint(_ style: SuggestionMark.Style, appearance: NSAppearance? = nil) -> NSColor {
        let dark = isDark(appearance)
        switch style {
        case .pending: return suggestionNS.withAlphaComponent(dark ? 0.16 : 0.09)
        case .ready: return suggestionNS.withAlphaComponent(dark ? 0.30 : 0.18)
        case .stale: return NSColor.systemGray.withAlphaComponent(dark ? 0.25 : 0.16)
        // Accepted rewrites only get an underline, so the text reads plainly.
        case .accepted, .history: return .clear
        }
    }

    /// Passages linked across the two sides (blue, apart from moves' purple
    /// and split/merge teal).
    static let linkNS = NSColor.systemBlue
    static var link: Color { Color(nsColor: linkNS) }

    static func linkTint(highlighted: Bool, appearance: NSAppearance? = nil) -> NSColor {
        let dark = isDark(appearance)
        return highlighted ? linkNS.withAlphaComponent(dark ? 0.30 : 0.18) : linkNS.withAlphaComponent(dark ? 0.10 : 0.06)
    }

    /// Parts of a suggestion rewritten on their own, in its card (pink, apart
    /// from the suggestion's indigo and the diff's green and red).
    static let refinedNS = NSColor.systemPink
    static var refined: Color { Color(nsColor: refinedNS) }

    static func suggestionUnderline(_ style: SuggestionMark.Style) -> NSColor {
        if style == .accepted { return suggestionNS.withAlphaComponent(0.55) }
        return style == .stale || style == .history ? .systemGray : suggestionNS
    }

    /// Text highlighted as a source for AI rewrites (cyan, like a highlighter pen).
    static let sourceMarkNS = NSColor.systemCyan
    static var sourceMark: Color { Color(nsColor: sourceMarkNS) }

    static func sourceMarkTint(appearance: NSAppearance? = nil) -> NSColor {
        sourceMarkNS.withAlphaComponent(isDark(appearance) ? 0.24 : 0.16)
    }

    /// Comments: a soft amber wash with an orange underline, so they read as
    /// notes rather than as a diff change or an AI suggestion.
    static let commentNS = NSColor.systemOrange
    static var comment: Color { Color(nsColor: commentNS) }

    static func commentTint(resolved: Bool, appearance: NSAppearance? = nil) -> NSColor {
        let dark = isDark(appearance)
        if resolved { return NSColor.systemGray.withAlphaComponent(dark ? 0.20 : 0.12) }
        return NSColor.systemYellow.withAlphaComponent(dark ? 0.24 : 0.26)
    }

    static func commentUnderline(resolved: Bool) -> NSColor {
        resolved ? .systemGray : commentNS
    }

    static func gutterMark(_ style: EditorHighlights.Style) -> NSColor {
        switch style {
        case .removed: return removedNS
        case .added: return addedNS
        case .modified: return modifiedNS
        case .moved: return movedNS
        }
    }

    // SwiftUI equivalents for the output view.
    static func rowTint(_ kind: RowKind, side: DiffDocument.Side, moved: Bool, dark: Bool) -> Color {
        if moved { return moved_(dark ? 0.20 : 0.11) }
        switch kind {
        case .unchanged: return .clear
        case .modified, .removed, .added:
            return side == .left ? removed.opacity(dark ? 0.16 : 0.10) : added.opacity(dark ? 0.16 : 0.10)
        }
    }

    static func emphasis(side: DiffDocument.Side, moved: Bool, dark: Bool) -> Color {
        if moved { return moved_(dark ? 0.45 : 0.28) }
        return side == .left ? removed.opacity(dark ? 0.45 : 0.30) : added.opacity(dark ? 0.45 : 0.30)
    }

    private static func moved_(_ opacity: Double) -> Color { moved.opacity(opacity) }

    static func color(for category: DiffInsights.Category) -> Color {
        switch category {
        case .unchanged: return unchanged
        case .modified: return modified
        case .removed: return removed
        case .added: return added
        case .moved: return moved
        }
    }
}
