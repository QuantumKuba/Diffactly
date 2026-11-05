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
