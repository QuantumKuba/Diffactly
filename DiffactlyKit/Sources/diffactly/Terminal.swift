import Foundation

/// ANSI styling that switches itself off when colour is disabled.
struct Style {
    let enabled: Bool

    private func wrap(_ s: String, _ code: String) -> String {
        enabled && !s.isEmpty ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s
    }

    func bold(_ s: String) -> String { wrap(s, "1") }
    func dim(_ s: String) -> String { wrap(s, "2") }
    func header(_ s: String) -> String { wrap(s, "1") }
    func hunk(_ s: String) -> String { wrap(s, "36") }

    func removed(_ s: String) -> String { wrap(s, "31") }
    func added(_ s: String) -> String { wrap(s, "32") }
    func moved(_ s: String) -> String { wrap(s, "35") }
    func modifiedMark(_ s: String) -> String { wrap(s, "33") }

    /// Highlight for the exact changed text inside a line (reverse video stays
    /// readable on both light and dark terminals).
    func removedEmphasis(_ s: String) -> String { wrap(s, "1;7;31") }
    func addedEmphasis(_ s: String) -> String { wrap(s, "1;7;32") }
    func movedEmphasis(_ s: String) -> String { wrap(s, "1;7;35") }

    func paint(_ s: String, role: Role, emphasis: Bool = false) -> String {
        switch (role, emphasis) {
        case (.plain, _): return s
        case (.removed, false): return removed(s)
        case (.removed, true): return removedEmphasis(s)
        case (.added, false): return added(s)
        case (.added, true): return addedEmphasis(s)
        case (.moved, false): return moved(s)
        case (.moved, true): return movedEmphasis(s)
        }
    }

    enum Role { case plain, removed, added, moved }
}

enum Terminal {
    static var isTTY: Bool { isatty(STDOUT_FILENO) == 1 }

    static func colorEnabled(_ mode: ColorMode) -> Bool {
        switch mode {
        case .always: return true
        case .never: return false
        case .auto:
            let env = ProcessInfo.processInfo.environment
            if env["NO_COLOR"] != nil { return false }
            if env["TERM"] == "dumb" { return false }
            // git pipes external diffs through its pager.
            if env["GIT_PAGER_IN_USE"] == "true" { return true }
            return isTTY
        }
    }

    static var width: Int {
        var w = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0, w.ws_col >= 40 { return Int(w.ws_col) }
        if let cols = ProcessInfo.processInfo.environment["COLUMNS"].flatMap(Int.init), cols >= 40 { return cols }
        return 120
    }
}

/// Monospace display width (East Asian wide characters and emoji take two cells).
func displayWidth(_ ch: Character) -> Int {
    guard let scalar = ch.unicodeScalars.first else { return 0 }
    if ch == "\t" { return 4 }
    let v = scalar.value
    if scalar.properties.generalCategory == .nonspacingMark || scalar.properties.generalCategory == .enclosingMark { return 0 }
    if scalar.properties.isEmojiPresentation || (ch.unicodeScalars.count > 1 && scalar.properties.isEmoji) { return 2 }
    switch v {
    case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
         0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
         0xFFE0...0xFFE6, 0x20000...0x3FFFD:
        return 2
    default:
        return 1
    }
}

func displayWidth(_ s: String) -> Int { s.reduce(0) { $0 + displayWidth($1) } }

/// A run of text with a styling flag, used to wrap highlighted lines.
struct StyledRun {
    var text: String
    var emphasis: Bool
}

/// Wraps styled runs to `width` cells, returning one array of runs per visual line.
func wrap(_ runs: [StyledRun], width: Int) -> [[StyledRun]] {
    guard width > 0 else { return [runs] }
    var lines: [[StyledRun]] = [[]]
    var used = 0
    for run in runs {
        var buffer = ""
        for ch in run.text {
            let rendered: String = ch == "\t" ? "    " : String(ch)
            let w = displayWidth(ch)
            if used + w > width, used > 0 {
                if !buffer.isEmpty { lines[lines.count - 1].append(StyledRun(text: buffer, emphasis: run.emphasis)) }
                buffer = ""
                lines.append([])
                used = 0
            }
            buffer += rendered
            used += w
        }
        if !buffer.isEmpty { lines[lines.count - 1].append(StyledRun(text: buffer, emphasis: run.emphasis)) }
    }
    return lines
}

func pad(_ s: String, to width: Int) -> String {
    let w = displayWidth(s)
    return w >= width ? s : s + String(repeating: " ", count: width - w)
}

func leftPad(_ s: String, to width: Int) -> String {
    let w = displayWidth(s)
    return w >= width ? s : String(repeating: " ", count: width - w) + s
}
