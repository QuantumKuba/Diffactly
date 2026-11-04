import XCTest
@testable import DiffactlyCore

final class DiffEngineTests: XCTestCase {

    // MARK: Helpers

    private func changed(_ line: DiffLine?) -> [String] {
        (line?.segments ?? []).filter(\.isChanged).map(\.text)
    }

    private func rows(_ result: DiffResult, _ kind: RowKind) -> [DiffRow] {
        result.rows.filter { $0.kind == kind }
    }

    // MARK: Basics

    func testIdenticalTexts() {
        let r = DiffEngine.compare("a\nb\nc\n", "a\nb\nc\n")
        XCTAssertTrue(r.isIdentical)
        XCTAssertEqual(r.rows.count, 3)
        XCTAssertEqual(r.stats.similarity, 1)
    }

    func testEmptyInputs() {
        XCTAssertTrue(DiffEngine.compare("", "").isIdentical)
        let added = DiffEngine.compare("", "x\ny\n")
        XCTAssertEqual(added.stats.addedLines, 2)
        XCTAssertEqual(added.stats.removedLines, 0)
        let removed = DiffEngine.compare("x\ny\n", "")
        XCTAssertEqual(removed.stats.removedLines, 2)
    }

    func testInsertedLinesKeepSurroundingsUnchanged() {
        let r = DiffEngine.compare("one\ntwo\nthree\n", "one\ntwo\nnew line\nthree\n")
        XCTAssertEqual(r.stats.addedLines, 1)
        XCTAssertEqual(r.stats.unchangedLines, 3)
        XCTAssertEqual(r.hunks.count, 1)
        XCTAssertEqual(rows(r, .added).first?.right?.number, 3)
    }

    // MARK: Accuracy (the cases the old analyzer special-cased)

    func testCodeEditsArePairedAndHighlightedPrecisely() {
        let old = """
        function calculateTotal(items) {
            let total = 0;
            for (let i = 0; i < items.length; i++) {
                total += items[i].price;
            }
            return total;
        }
        """
        let new = """
        function calculateTotal(items) {
            let sum = 0;
            for (const item of items) {
                sum += item.price;
            }
            return sum;
        }
        """
        let r = DiffEngine.compare(old, new, options: DiffOptions(level: .word))
        XCTAssertEqual(r.stats.modifiedLines, 4, "lines 2, 3, 4 and 6 are edits of each other")
        XCTAssertEqual(r.stats.addedLines, 0)
        XCTAssertEqual(r.stats.removedLines, 0)
        let modified = rows(r, .modified)
        XCTAssertEqual(modified.map { $0.left!.number }, [2, 3, 4, 6])
        XCTAssertEqual(changed(modified[0].left), ["total"])
        XCTAssertEqual(changed(modified[0].right), ["sum"])
        XCTAssertEqual(changed(modified[3].left), ["total"])
        // Unchanged lines stay unchanged.
        XCTAssertEqual(r.rows.first?.kind, .unchanged)
        XCTAssertEqual(r.rows.last?.kind, .unchanged)
    }

    func testProseWordLevel() {
        let r = DiffEngine.compare(
            "The quick brown fox jumps over the lazy dog.",
            "The fast brown fox leaps over the sleepy dog.",
            options: DiffOptions(level: .word)
        )
        let row = r.rows[0]
        XCTAssertEqual(row.kind, .modified)
        XCTAssertEqual(changed(row.left), ["quick", "jumps", "lazy"])
        XCTAssertEqual(changed(row.right), ["fast", "leaps", "sleepy"])
    }

    func testSmartLevelRefinesTyposButKeepsRewritesWhole() {
        let r = DiffEngine.compare("The colour of the quick fox", "The color of the fast fox")
        let row = r.rows[0]
        XCTAssertEqual(changed(row.left), ["u", "quick"])
        XCTAssertEqual(changed(row.right), ["fast"])
    }

    func testCharacterLevelDoesNotSplitEmoji() {
        let r = DiffEngine.compare("Watch movie 🎬 now", "Watch series 📺 now", options: DiffOptions(level: .character))
        let row = r.rows[0]
        for seg in row.left!.segments + row.right!.segments {
            XCTAssertFalse(seg.text.unicodeScalars.contains { $0.value == 0xFFFD })
        }
        XCTAssertTrue(changed(row.left).joined().contains("🎬"))
        XCTAssertTrue(changed(row.right).joined().contains("📺"))
    }

    func testEmojiTextLines() {
        let old = "Hello! 👋 Here's my weekend plan:\n• Go shopping 🛍️\n• Meet friends for café ☕️\n• Watch movie @ home 🎬"
        let new = "Hi there! 👋 Here's my weekend schedule:\n• Go shopping with mom 🛍️\n• Meet friends for lunch 🍽️\n• Watch series @ home 📺"
        let r = DiffEngine.compare(old, new, options: DiffOptions(level: .word))
        XCTAssertEqual(r.stats.modifiedLines, 4)
        XCTAssertEqual(changed(r.rows[1].right), ["with mom "])
        XCTAssertEqual(changed(r.rows[0].left), ["Hello", "plan"])
    }

    // MARK: Whitespace / ignore options

    func testReindentedLinesAlignAndShowWhitespaceChange() {
        let r = DiffEngine.compare("if x {\nfoo()\n}\n", "if x {\n    foo()\n}\n")
        XCTAssertEqual(r.stats.modifiedLines, 1)
        XCTAssertEqual(changed(r.rows[1].right), ["    "])
        let ignoring = DiffEngine.compare("if x {\nfoo()\n}\n", "if x {\n    foo()\n}\n", options: DiffOptions(ignoreWhitespace: true))
        XCTAssertTrue(ignoring.isIdentical)
        XCTAssertTrue(ignoring.rows[1].hasIgnoredDifferences)
    }

    func testIgnoreCaseQuotesDashesAndCustomStrings() {
        XCTAssertTrue(DiffEngine.compare("Hello World", "hello world", options: DiffOptions(ignoreCase: true)).isIdentical)
        XCTAssertFalse(DiffEngine.compare("Hello World", "hello world").isIdentical)
        XCTAssertTrue(DiffEngine.compare("“quoted”", "\"quoted\"", options: DiffOptions(ignoreQuotes: true)).isIdentical)
        XCTAssertTrue(DiffEngine.compare("a – b", "a - b", options: DiffOptions(ignoreDashes: true)).isIdentical)
        let custom = DiffEngine.compare("price: 10 USD", "price: 10", options: DiffOptions(ignoreWhitespace: true, ignoredStrings: ["USD"]))
        XCTAssertTrue(custom.isIdentical)
        // Ignored text inside a line with real changes is not highlighted.
        let partial = DiffEngine.compare("value = 1 // TODO", "value = 2 //", options: DiffOptions(level: .word, ignoreWhitespace: true, ignoredStrings: ["TODO"]))
        XCTAssertEqual(changed(partial.rows[0].left), ["1"])
    }

    // MARK: Moves

    func testMovedBlockIsDetected() {
        let block = "func helper() {\n    print(\"helping\")\n    return 42\n}\n"
        let old = "import Foundation\n\n" + block + "\nfunc main() {\n    run()\n}\n"
        let new = "import Foundation\n\nfunc main() {\n    run()\n}\n\n" + block
        let r = DiffEngine.compare(old, new)
        // Swapping two blocks: the heavier `helper` block stays anchored and the
        // smaller `main` block (plus its blank separator) is reported as moved.
        XCTAssertEqual(r.moves.count, 1)
        XCTAssertEqual(r.moves[0].from, 6...9)
        XCTAssertEqual(r.moves[0].to, 3...6)
        XCTAssertEqual(r.moves[0].similarity, 1)
        XCTAssertEqual(r.stats.movedLines, 4)
        XCTAssertEqual(r.stats.removedLines + r.stats.addedLines, 0)
        let noMoves = DiffEngine.compare(old, new, options: DiffOptions(detectMoves: false))
        XCTAssertTrue(noMoves.moves.isEmpty)
        XCTAssertEqual(noMoves.stats.movedLines, 0)
    }

    func testMovedAndEditedBlockIsDetectedWithInlineChanges() {
        let fn = { (v: String, loop: String, item: String) in
            "function calculateTotal(items) {\n    let \(v) = 0;\n    \(loop)\n        \(v) += \(item).price;\n    }\n    return \(v);\n}\n"
        }
        let helper = "function helper() {\n    console.log(\"helping out\");\n    return 42;\n}\n"
        let old = "import { api } from \"./api\";\n\n" + fn("total", "for (let i = 0; i < items.length; i++) {", "items[i]") + "\n" + helper + "\nexport default calculateTotal;\n"
        let new = "import { api } from \"./api\";\n\n" + helper + "\n" + fn("sum", "for (const item of items) {", "item") + "\nexport default calculateTotal;\n"
        let r = DiffEngine.compare(old, new)
        XCTAssertEqual(r.moves.count, 1)
        let move = r.moves[0]
        XCTAssertLessThan(move.similarity, 1)
        XCTAssertGreaterThanOrEqual(move.from.count, 5)
        // The moved `let total = 0;` line highlights only the renamed variable.
        let movedLet = r.rows.first { $0.moveID == move.id && $0.left?.text.contains("let total") == true }
        XCTAssertEqual(changed(movedLet?.left), ["total"])
        // An exact move carries no emphasis at all.
        let anchor = "this anchor paragraph stays in place\nand is much heavier than the block\nthat moves around it\n"
        let exact = DiffEngine.compare("a1\nb22\nc333\n" + anchor, anchor + "a1\nb22\nc333\n")
        XCTAssertEqual(exact.moves.count, 1)
        XCTAssertTrue(exact.rows.filter { $0.moveID != nil }.allSatisfy { !($0.left ?? $0.right)!.hasChangedSegments })
    }

    // MARK: Line endings

    func testTrailingNewlineDifferenceIsReported() {
        let r = DiffEngine.compare("a\nb", "a\nb\n")
        XCTAssertFalse(r.isIdentical)
        XCTAssertTrue(r.stats.trailingNewlineDiffers)
        let patch = UnifiedFormatter.patch(r)
        XCTAssertTrue(patch.contains("\\ No newline at end of file"))
    }

    func testCRLFIsNotAContentChange() {
        let r = DiffEngine.compare("a\r\nb\r\n", "a\nb\n")
        XCTAssertTrue(r.isIdentical)
        XCTAssertTrue(r.stats.lineEndingsDiffer)
    }

    // MARK: Invariants

    func testRoundTripOnRandomEdits() {
        var rng = SeededGenerator(seed: 42)
        let vocabulary = ["alpha", "beta", "gamma", "delta", "{", "}", "", "    return x", "let y = 1", "// note", "é ü", "🙂 ok"]
        for _ in 0..<200 {
            let a = (0..<Int.random(in: 0...25, using: &rng)).map { _ in vocabulary.randomElement(using: &rng)! }
            var b = a
            for _ in 0..<Int.random(in: 0...6, using: &rng) {
                switch Int.random(in: 0..<4, using: &rng) {
                case 0 where !b.isEmpty: b.remove(at: Int.random(in: 0..<b.count, using: &rng))
                case 1: b.insert(vocabulary.randomElement(using: &rng)!, at: Int.random(in: 0...b.count, using: &rng))
                case 2 where !b.isEmpty: b[Int.random(in: 0..<b.count, using: &rng)] += " edited"
                default: b.shuffle(using: &rng)
                }
            }
            let left = a.joined(separator: "\n") + (Bool.random(using: &rng) ? "\n" : "")
            let right = b.joined(separator: "\n") + (Bool.random(using: &rng) ? "\n" : "")
            for level in DiffLevel.allCases {
                let r = DiffEngine.compare(left, right, options: DiffOptions(level: level))
                XCTAssertEqual(r.rows.compactMap(\.left).map(\.text), SideText(left).lines)
                XCTAssertEqual(r.rows.compactMap(\.right).map(\.text), SideText(right).lines)
                XCTAssertEqual(r.rows.compactMap(\.left).map(\.number), Array(1...max(1, SideText(left).lines.count)).prefix(SideText(left).lines.count).map { $0 })
                for row in r.rows {
                    if let l = row.left { XCTAssertEqual(l.segments.map(\.text).joined(), l.text) }
                    if let rr = row.right { XCTAssertEqual(rr.segments.map(\.text).joined(), rr.text) }
                }
                XCTAssertEqual(r.isIdentical, left == right)
            }
        }
    }

    func testPatchAppliesWithSystemPatch() throws {
        var rng = SeededGenerator(seed: 7)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("diffactly-patch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let words = ["red", "green", "blue", "x = 1", "x = 2", "", "end", "begin", "  indented"]
        for iteration in 0..<40 {
            let a = (0..<Int.random(in: 1...30, using: &rng)).map { _ in words.randomElement(using: &rng)! }
            var b = a
            for _ in 0..<Int.random(in: 1...5, using: &rng) {
                if Bool.random(using: &rng), !b.isEmpty { b.remove(at: Int.random(in: 0..<b.count, using: &rng)) }
                else { b.insert(words.randomElement(using: &rng)!, at: Int.random(in: 0...b.count, using: &rng)) }
            }
            let left = a.joined(separator: "\n") + (iteration % 3 == 0 ? "" : "\n")
            let right = b.joined(separator: "\n") + (iteration % 4 == 0 ? "" : "\n")
            let r = DiffEngine.compare(left, right)
            let patchText = UnifiedFormatter.patch(r, leftLabel: "file", rightLabel: "file")
            if left == right { XCTAssertEqual(patchText, ""); continue }
            let file = dir.appendingPathComponent("file")
            try left.write(to: file, atomically: true, encoding: .utf8)
            let patchFile = dir.appendingPathComponent("p.diff")
            try patchText.write(to: patchFile, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/patch")
            p.arguments = ["-s", "--no-backup-if-mismatch", file.path, patchFile.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "patch failed:\n\(patchText)")
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), right, "iteration \(iteration)\n\(patchText)")
        }
    }

    func testLargeInputIsFast() {
        let a = (0..<20_000).map { "line \($0) with some content" }.joined(separator: "\n")
        var lines = a.components(separatedBy: "\n")
        for i in stride(from: 0, to: lines.count, by: 97) { lines[i] += " changed" }
        lines.insert(contentsOf: ["inserted"], at: 5000)
        let b = lines.joined(separator: "\n")
        let start = Date()
        let r = DiffEngine.compare(a, b)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(r.stats.addedLines, 1)
        XCTAssertEqual(r.stats.modifiedLines, 207)
    }

    // MARK: Insights / transforms

    func testInsights() {
        let r = DiffEngine.compare("a\nb\nc\nd\n", "a\nB\nc\nd\ne\n")
        let map = DiffInsights.changeMap(r, buckets: 5)
        XCTAssertEqual(map.reduce(0) { $0 + $1.total }, 2)
        let shifts = DiffInsights.wordShifts(left: "total total total sum", right: "sum sum sum total")
        XCTAssertEqual(shifts.map(\.word), ["sum", "total"])
        XCTAssertEqual(shifts.map(\.delta), [2, -2])
    }

    func testTransforms() {
        XCTAssertEqual(TextTransform.sortLines.apply(to: "b\na\nc\n"), "a\nb\nc\n")
        XCTAssertEqual(TextTransform.joinLines.apply(to: "a\nb\n\nc"), "a b c")
        XCTAssertEqual(TextTransform.trimWhitespace.apply(to: "  a \n\tb\n"), "a\nb\n")
        XCTAssertEqual(TextTransform.lowercase.apply(to: "AbC"), "abc")
    }
}

/// Deterministic RNG so randomized tests are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2685821657736338717
    }
}
