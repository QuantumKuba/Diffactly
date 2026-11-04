import Foundation
import DiffactlyCore

enum OutputFormat: String, CaseIterable {
    case unified, split, inline, patch, stats, json
}

enum ColorMode: String {
    case auto, always, never
}

struct CommandLineOptions {
    var diff = DiffOptions()
    var format: OutputFormat?
    var graph = false
    var context = 3
    var full = false
    var width: Int?
    var color = ColorMode.auto
    var labels: (String, String)?
    var brief = false
    var gui = false
    var transforms: [TextTransform] = []
    var positional: [String] = []
    var showHelp = false
    var showVersion = false
}

struct UsageError: Error, CustomStringConvertible {
    var description: String
}

enum ArgumentParser {
    static func parse(_ args: [String]) throws -> CommandLineOptions {
        var o = CommandLineOptions()
        var i = 0
        var onlyPositional = false

        func value(_ name: String, inline: String?) throws -> String {
            if let inline { return inline }
            i += 1
            guard i < args.count else { throw UsageError(description: "option \(name) needs a value") }
            return args[i]
        }

        while i < args.count {
            let arg = args[i]
            if onlyPositional || arg == "-" || !arg.hasPrefix("-") {
                o.positional.append(arg)
                i += 1
                continue
            }
            if arg == "--" { onlyPositional = true; i += 1; continue }

            // Split --name=value and -Uvalue forms.
            var name = arg
            var inline: String? = nil
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                name = String(arg[..<eq])
                inline = String(arg[arg.index(after: eq)...])
            } else if arg.count > 2, !arg.hasPrefix("--"), ["-U", "-W", "-f", "-l", "-t"].contains(String(arg.prefix(2))) {
                name = String(arg.prefix(2))
                inline = String(arg.dropFirst(2))
            } else if arg.count > 2, !arg.hasPrefix("--") {
                // Bundled boolean short flags: -wi, -qw …
                let flags = arg.dropFirst().map { "-\($0)" }
                if flags.allSatisfy({ ["-w", "-i", "-q", "-s", "-g", "-h"].contains($0) }) {
                    for f in flags { try apply(flag: f, to: &o) }
                    i += 1
                    continue
                }
            }

            switch name {
            case "-f", "--format":
                let v = try value(name, inline: inline)
                guard let f = OutputFormat(rawValue: v) else {
                    throw UsageError(description: "unknown format '\(v)' (expected \(OutputFormat.allCases.map(\.rawValue).joined(separator: ", ")))")
                }
                o.format = f
            case "-l", "--level":
                let v = try value(name, inline: inline)
                switch v {
                case "smart": o.diff.level = .smart
                case "word", "words": o.diff.level = .word
                case "char", "chars", "character", "characters": o.diff.level = .character
                default: throw UsageError(description: "unknown level '\(v)' (expected smart, word or char)")
                }
            case "-U", "--context", "--unified":
                let v = try value(name, inline: inline)
                guard let n = Int(v), n >= 0 else { throw UsageError(description: "context must be a non-negative number") }
                o.context = n
            case "-W", "--width":
                let v = try value(name, inline: inline)
                guard let n = Int(v), n >= 40 else { throw UsageError(description: "width must be a number ≥ 40") }
                o.width = n
            case "--color", "--colour":
                var v = inline ?? "always"
                if inline == nil, i + 1 < args.count, ColorMode(rawValue: args[i + 1]) != nil {
                    i += 1
                    v = args[i]
                }
                guard let c = ColorMode(rawValue: v) else { throw UsageError(description: "color must be auto, always or never") }
                o.color = c
            case "--no-color", "--no-colour":
                o.color = .never
            case "--labels", "--label":
                let l = try value(name, inline: inline)
                let r = try value(name, inline: nil)
                o.labels = (l, r)
            case "--ignore":
                o.diff.ignoredStrings.append(try value(name, inline: inline))
            case "-t", "--transform":
                for part in try value(name, inline: inline).split(separator: ",") {
                    let key = part.trimmingCharacters(in: .whitespaces).lowercased()
                    let match = TextTransform.allCases.first { $0.rawValue.lowercased() == key }
                        ?? (key == "lower" ? .lowercase : nil)
                    guard let match else {
                        throw UsageError(description: "unknown transform '\(key)' (expected lowercase, sort, join, trim)")
                    }
                    o.transforms.append(match)
                }
            case "--ignore-quotes": o.diff.ignoreQuotes = true
            case "--ignore-dashes": o.diff.ignoreDashes = true
            case "--no-moves": o.diff.detectMoves = false
            case "--full": o.full = true
            case "--gui": o.gui = true
            case "--version", "-V": o.showVersion = true
            default:
                try apply(flag: name, to: &o)
            }
            i += 1
        }
        return o
    }

    private static func apply(flag: String, to o: inout CommandLineOptions) throws {
        switch flag {
        case "-w", "--ignore-whitespace", "--ignore-all-space": o.diff.ignoreWhitespace = true
        case "-i", "--ignore-case": o.diff.ignoreCase = true
        case "-q", "--brief", "--quiet": o.brief = true
        case "-s", "--stat", "--stats": o.format = .stats
        case "-g", "--graph", "--graphs": o.graph = true
        case "-h", "--help": o.showHelp = true
        default: throw UsageError(description: "unknown option '\(flag)'")
        }
    }

    static let help = """
    diffactly — accurate text diffs, in the terminal and in Diffactly.app

    USAGE
      diffactly [options] <original> <changed>      compare two files (- reads stdin)
      diffactly [options] <dir-a> <dir-b>           compare two folders recursively
      diffactly git <path> <old-file> <old-hex> <old-mode> <new-file> <new-hex> <new-mode>
                                                git external-diff driver

    OUTPUT
      -f, --format <fmt>      unified (default), split, inline, patch, stats, json
      -g, --graph             add insight graphs: similarity, composition,
                              where changes are (change map) and word shifts
      -s, --stat              shorthand for --format stats
      -U, --context <n>       unchanged lines around each change (default 3)
          --full              show every line
      -W, --width <cols>      width of split output (default: terminal width)
          --color[=<when>]    auto (default), always, never   (NO_COLOR is honoured)
          --labels <l> <r>    names shown for the two sides
      -q, --brief             no output; only the exit status says if inputs differ
          --gui               open the comparison in Diffactly.app

    COMPARISON
      -l, --level <level>     smart (default), word, char
      -w, --ignore-whitespace ignore all whitespace differences
      -i, --ignore-case       ignore case differences
          --ignore-quotes     treat straight and curly quotes alike
          --ignore-dashes     treat -, –, — and − alike
          --ignore <text>     never count <text> as a difference (repeatable)
          --no-moves          don't detect moved blocks
      -t, --transform <list>  lowercase, sort, join, trim — applied to both sides

    EXIT STATUS
      0 inputs are the same · 1 inputs differ · 2 trouble

    GIT
      git config --global diff.external "diffactly git"   # every `git diff`
      GIT_EXTERNAL_DIFF="diffactly git -l word" git diff   # one-off, with options
      git difftool -y -x "diffactly --gui"                 # review in Diffactly.app

    EXAMPLES
      diffactly old.txt new.txt
      diffactly -f split -l word draft-1.md draft-2.md
      diffactly -s -g before.json after.json
      curl -s https://example.com | diffactly saved.html -
    """
}
