import Foundation
import DiffactlyCore

let version = "diffactly 1.0.0"

// MARK: - Output helpers

func write(_ s: String) {
    guard !s.isEmpty else { return }
    FileHandle.standardOutput.write(s.data(using: .utf8)!)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("diffactly: \(message)\n".data(using: .utf8)!)
    exit(2)
}

// MARK: - Inputs

struct Input {
    var label: String
    var text: String
    var isBinary: Bool
    var data: Data
}

func readInput(_ path: String) -> Input {
    let data: Data
    if path == "-" {
        data = FileHandle.standardInput.readDataToEndOfFile()
    } else if path == "/dev/null" {
        data = Data()
    } else {
        guard let d = FileManager.default.contents(atPath: path) else {
            fail("cannot read '\(path)'")
        }
        data = d
    }
    let binary = data.prefix(8000).contains(0)
    let text = binary ? "" : (String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self))
    return Input(label: path == "-" ? "(stdin)" : path, text: text, isBinary: binary, data: data)
}

func isDirectory(_ path: String) -> Bool {
    var dir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
}

// MARK: - Rendering one comparison

func render(_ result: DiffResult, left: Input, right: Input, labels: (String, String), options o: CommandLineOptions, defaultFormat: OutputFormat = .unified) -> String {
    let ctx = RenderContext(
        result: result, leftText: left.text, rightText: right.text,
        leftLabel: labels.0, rightLabel: labels.1,
        style: Style(enabled: Terminal.colorEnabled(o.color)),
        context: o.full ? nil : o.context,
        width: o.width ?? Terminal.width
    )
    var out: String
    switch o.format ?? defaultFormat {
    case .unified: out = renderUnified(ctx)
    case .patch: out = UnifiedFormatter.patch(result, leftLabel: labels.0, rightLabel: labels.1, context: o.full ? Int.max / 4 : o.context)
    case .split: out = renderSplit(ctx)
    case .inline: out = result.isIdentical ? "" : renderInline(ctx)
    case .stats: return renderStats(ctx, graph: o.graph)
    case .json: return renderJSON(ctx)
    }
    if o.graph, !result.isIdentical {
        out += "\n" + renderGraphs(ctx)
    }
    return out
}

func transformed(_ text: String, _ transforms: [TextTransform]) -> String {
    transforms.reduce(text) { $1.apply(to: $0) }
}

// MARK: - GUI hand-off

func openInDiffactly(_ left: Input, _ right: Input, leftPath: String, rightPath: String) -> Never {
    func materialise(_ input: Input, _ path: String, _ name: String) -> String {
        if path != "-" && path != "/dev/null" { return path }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diffactly-\(UUID().uuidString.prefix(8))-\(name)")
        FileManager.default.createFile(atPath: url.path, contents: input.data)
        return url.path
    }
    let paths = [materialise(left, leftPath, "original.txt"), materialise(right, rightPath, "changed.txt")]
    for attempt in [["-b", "Minimal.Diffactly"], ["-a", "Diffactly"]] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = attempt + paths
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 { exit(0) }
        } catch {}
    }
    fail("could not open Diffactly.app — is it installed?")
}

// MARK: - Folder comparison

func files(in root: String) -> Set<String> {
    let base = URL(fileURLWithPath: root).standardizedFileURL
    var out = Set<String>()
    guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]) else { return out }
    for case let url as URL in e {
        let name = url.lastPathComponent
        if name == ".git" || name == ".DS_Store" || name == ".build" || name == "node_modules" {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { e.skipDescendants() }
            continue
        }
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
        let rel = String(url.standardizedFileURL.path.dropFirst(base.path.count + 1))
        out.insert(rel)
    }
    return out
}

func compareDirectories(_ a: String, _ b: String, _ o: CommandLineOptions) -> Int32 {
    let left = files(in: a), right = files(in: b)
    let all = left.union(right).sorted()
    let style = Style(enabled: Terminal.colorEnabled(o.color))
    var differs = false
    var summary: [(status: String, path: String, added: Int, removed: Int)] = []
    var details = ""

    for rel in all {
        let lp = (a as NSString).appendingPathComponent(rel)
        let rp = (b as NSString).appendingPathComponent(rel)
        let li = left.contains(rel) ? readInput(lp) : Input(label: "/dev/null", text: "", isBinary: false, data: Data())
        let ri = right.contains(rel) ? readInput(rp) : Input(label: "/dev/null", text: "", isBinary: false, data: Data())
        if left.contains(rel), right.contains(rel), li.data == ri.data { continue }
        differs = true
        let status = !left.contains(rel) ? "A" : (!right.contains(rel) ? "D" : "M")
        if li.isBinary || ri.isBinary {
            summary.append((status, rel, 0, 0))
            details += style.bold("Binary files \(left.contains(rel) ? "a/" + rel : "/dev/null") and \(right.contains(rel) ? "b/" + rel : "/dev/null") differ") + "\n"
            continue
        }
        let result = DiffEngine.compare(transformed(li.text, o.transforms), transformed(ri.text, o.transforms), options: o.diff)
        if result.isIdentical { continue }
        summary.append((status, rel, result.stats.additions, result.stats.removals))
        guard !o.brief, o.format != .stats else { continue }
        details += style.bold("diff diffactly a/\(rel) b/\(rel)") + "\n"
        details += render(result, left: li, right: ri,
                          labels: (left.contains(rel) ? "a/\(rel)" : "/dev/null", right.contains(rel) ? "b/\(rel)" : "/dev/null"),
                          options: o)
    }

    if o.brief {
        for s in summary { write("Files \(a)/\(s.path) and \(b)/\(s.path) differ\n") }
        return differs ? 1 : 0
    }

    if o.format == .stats {
        let pathWidth = min(60, summary.map { displayWidth($0.path) }.max() ?? 10)
        for s in summary {
            let mark: String
            switch s.status {
            case "A": mark = style.added("A")
            case "D": mark = style.removed("D")
            default: mark = style.modifiedMark("M")
            }
            write(" \(mark)  \(pad(s.path, to: pathWidth))  \(style.added("+\(s.added)")) \(style.removed("−\(s.removed)"))\n")
        }
        let added = summary.filter { $0.status == "A" }.count, removed = summary.filter { $0.status == "D" }.count
        write(style.dim(" \(summary.count) file\(summary.count == 1 ? "" : "s") changed · \(added) added · \(removed) deleted · \(summary.count - added - removed) modified") + "\n")
    } else {
        write(details)
    }
    return differs ? 1 : 0
}

// MARK: - git external diff driver

/// `git` invokes: path old-file old-hex old-mode new-file new-hex new-mode [new-path rename-info]
func runGitDriver(_ args: [String]) -> Never {
    var o: CommandLineOptions
    do { o = try ArgumentParser.parse(args) } catch { fail("\(error)") }
    let p = o.positional
    guard p.count == 7 || p.count == 9 else {
        fail("git mode expects the 7 (or 9) arguments git passes to an external diff tool; see `diffactly --help`")
    }
    let path = p[0], newPath = p.count == 9 ? p[7] : p[0]
    let left = readInput(p[1]), right = readInput(p[4])
    let style = Style(enabled: Terminal.colorEnabled(o.color))
    let leftLabel = p[1] == "/dev/null" ? "/dev/null" : "a/\(path)"
    let rightLabel = p[4] == "/dev/null" ? "/dev/null" : "b/\(newPath)"

    if o.gui { openInDiffactly(left, right, leftPath: p[1], rightPath: p[4]) }
    write(style.bold("diff --diffactly a/\(path) b/\(newPath)") + "\n")
    if p[3] != p[6], p[3] != ".", p[6] != "." { write(style.dim("mode \(p[3]) → \(p[6])") + "\n") }
    if left.isBinary || right.isBinary {
        write("Binary files \(leftLabel) and \(rightLabel) differ\n")
        exit(0)
    }
    let result = DiffEngine.compare(transformed(left.text, o.transforms), transformed(right.text, o.transforms), options: o.diff)
    if result.isIdentical {
        if path != newPath { write(style.dim("renamed without changes") + "\n") }
        exit(0)
    }
    write(render(result, left: left, right: right, labels: (leftLabel, rightLabel), options: o))
    // git treats a non-zero status from an external diff as failure.
    exit(0)
}

// MARK: - Main

signal(SIGPIPE, SIG_DFL)
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "git" {
    runGitDriver(Array(arguments.dropFirst()))
}

let options: CommandLineOptions
do {
    options = try ArgumentParser.parse(arguments)
} catch {
    fail("\(error)\nRun `diffactly --help` for usage.")
}
if options.showHelp || arguments.isEmpty { write(ArgumentParser.help + "\n"); exit(arguments.isEmpty ? 2 : 0) }
if options.showVersion { write(version + "\n"); exit(0) }
guard options.positional.count == 2 else {
    fail("expected two files or folders to compare, got \(options.positional.count)\nRun `diffactly --help` for usage.")
}

let leftPath = options.positional[0], rightPath = options.positional[1]
if leftPath == "-" && rightPath == "-" { fail("only one side can be read from standard input") }

if isDirectory(leftPath) || isDirectory(rightPath) {
    guard isDirectory(leftPath) && isDirectory(rightPath) else { fail("cannot compare a folder with a file") }
    if options.gui { fail("--gui compares files, not folders") }
    exit(compareDirectories(leftPath, rightPath, options))
}

let leftInput = readInput(leftPath)
let rightInput = readInput(rightPath)
if options.gui { openInDiffactly(leftInput, rightInput, leftPath: leftPath, rightPath: rightPath) }

let labels = options.labels ?? (leftInput.label, rightInput.label)
if leftInput.isBinary || rightInput.isBinary {
    let same = leftInput.data == rightInput.data
    if !same && !options.brief { write("Binary files \(labels.0) and \(labels.1) differ\n") }
    exit(same ? 0 : 1)
}

let result = DiffEngine.compare(
    transformed(leftInput.text, options.transforms),
    transformed(rightInput.text, options.transforms),
    options: options.diff
)

if options.brief {
    if !result.isIdentical { write("Files \(labels.0) and \(labels.1) differ\n") }
    exit(result.isIdentical ? 0 : 1)
}

write(render(result, left: leftInput, right: rightInput, labels: labels, options: options))
exit(result.isIdentical ? 0 : 1)
