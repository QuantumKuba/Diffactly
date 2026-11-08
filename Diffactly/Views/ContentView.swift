import SwiftUI
import AppKit
import DiffactlyCore

struct ContentView: View {
    @StateObject private var document = DiffDocument()
    @State private var showIgnoreRules = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch document.mode {
                case .edit:
                    HStack(spacing: 0) {
                        EditorPane(document: document, side: .left)
                        Divider()
                        EditorPane(document: document, side: .right)
                    }
                case .split, .unified:
                    DiffOutputView(document: document, layout: document.mode)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                if document.search.isPresented {
                    SearchBarView(document: document)
                        .padding(.top, 8)
                        .padding(.trailing, 16)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity.combined(with: .move(edge: .top))
                        ))
                        .zIndex(100)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: document.search.isPresented)
            Divider()
            StatusBar(document: document)
        }
        .frame(minWidth: 760, minHeight: 440)
        .toolbar { DiffToolbar(document: document, showIgnoreRules: $showIgnoreRules) }
        .inspector(isPresented: $document.showInsights) {
            InsightsPanel(document: document)
                .inspectorColumnWidth(min: 260, ideal: 310, max: 460)
        }
        .navigationTitle("Diffactly")
        .navigationSubtitle(subtitle)
        .focusedSceneObject(document)
        .background(WindowObserver { window in DocumentRouter.shared.register(document, window: window) })
        .sheet(isPresented: $showIgnoreRules) { IgnoreRulesSheet(document: document) }
        .alert("Couldn’t open file", isPresented: Binding(get: { document.errorMessage != nil }, set: { if !$0 { document.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(document.errorMessage ?? "")
        }
    }

    private var subtitle: String {
        switch (document.leftName, document.rightName) {
        case let (l?, r?): return "\(l) ↔ \(r)"
        case let (l?, nil): return l
        case let (nil, r?): return r
        default: return ""
        }
    }
}

// MARK: - Editor pane

struct EditorPane: View {
    @ObservedObject var document: DiffDocument
    let side: DiffDocument.Side

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                EditableSplitTitle(document: document, side: side)
                if let name = side == .left ? document.leftName : document.rightName {
                    Label(name, systemImage: "doc.text")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                count
                Button {
                    document.showOpenPanel(for: side)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Open a file as the \(document.title(for: side).lowercased()) text")
                Menu {
                    Button("Open \(document.title(for: side))…") { document.showOpenPanel(for: side) }
                    Button("Paste") {
                        if let s = NSPasteboard.general.string(forType: .string) { document.setText(s, for: side) }
                    }
                    Divider()
                    Button("Clear", role: .destructive) { document.clear(side) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(.bar)
            .contentShape(Rectangle())
            .onTapGesture { document.activeSide = side }
            Divider()
            CodeEditor(
                text: side == .left ? $document.leftText : $document.rightText,
                highlights: side == .left ? document.leftHighlights : document.rightHighlights,
                placeholder: "Paste or drop the \(document.title(for: side).lowercased()) text…",
                wrapLines: document.wrapLines,
                focusRequest: document.focusRequest,
                focusLines: side == .left ? document.focusRequest?.leftLines : document.focusRequest?.rightLines,
                side: side,
                searchMatches: document.search.matches.filter { $0.side == side },
                currentMatch: document.search.currentMatch,
                isSearchPresented: document.search.isPresented,
                onFileDrop: { url in document.open(url, into: side) },
                onSelectionChange: { selected in document.updateSelection(side: side, selectedText: selected) },
                onFocus: { document.activeSide = side },
                onFind: { document.openSearch(focusedSide: side) },
                onFindNext: { document.findNext() },
                onFindPrevious: { document.findPrevious() },
                onUseSelection: { document.useSelectionForSearch() }
            )
        }
    }

    @ViewBuilder
    private var count: some View {
        let stats = document.result.stats
        if side == .left, stats.removals > 0 {
            Text("−\(stats.removals)").font(.caption.monospacedDigit()).foregroundStyle(DiffPalette.removed)
        } else if side == .right, stats.additions > 0 {
            Text("+\(stats.additions)").font(.caption.monospacedDigit()).foregroundStyle(DiffPalette.added)
        }
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @ObservedObject var document: DiffDocument

    /// The bar picks the richest layout that fits, so narrow windows (or an open
    /// Insights panel) drop detail instead of truncating labels mid-word.
    private enum Detail { case full, compact, minimal }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(.full)
            row(.compact)
            row(.minimal)
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.bar)
    }

    private func row(_ detail: Detail) -> some View {
        let stats = document.result.stats
        return HStack(spacing: 14) {
            if document.result.isIdentical {
                Label(document.leftText.isEmpty && document.rightText.isEmpty ? "Nothing to compare" : "Identical", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                chip("−\(stats.removals)", "removals", DiffPalette.removed)
                chip("+\(stats.additions)", "additions", DiffPalette.added)
                if stats.movedLines > 0 { chip("⇄ \(stats.movedLines)", "moved", DiffPalette.moved) }
                if detail != .minimal {
                    Text("\(Int((stats.similarity * 100).rounded(.down)))% similar").foregroundStyle(.secondary)
                }
            }
            if detail != .minimal, document.result.rows.contains(where: \.hasIgnoredDifferences) {
                Label("Ignored differences hidden", systemImage: "eye.slash").foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if document.isComputing {
                ProgressView().controlSize(.small)
            }
            if let selection = document.selection {
                selectionLabel(selection, detail)
            }
            wordTotals(detail)
            if detail != .minimal, document.hasChanges {
                Text(position).foregroundStyle(.secondary).monospacedDigit()
            }
            if detail == .full {
                Text(document.options.level.title)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Word counts

    /// "12 words, 68 chars selected" – only shown while text is selected in an editor.
    private func selectionLabel(_ selection: DiffDocument.SelectionCounts, _ detail: Detail) -> some View {
        let c = selection.counts
        let title = document.title(for: selection.side)
        let text = detail == .full
            ? "\(Self.plural(c.words, "word")), \(Self.plural(c.characters, "char")) selected"
            : "\(Self.plural(c.words, "word")) selected"
        return Text(text)
            .foregroundStyle(Color.accentColor)
            .monospacedDigit()
            .help("Selected in \(title.lowercased()) text: \(Self.plural(c.words, "word")), \(Self.plural(c.characters, "character")), \(Self.plural(c.lines, "line"))")
    }

    /// Total words per side with the net change, e.g. "Original 120 · Changed 134 words (+14)".
    @ViewBuilder
    private func wordTotals(_ detail: Detail) -> some View {
        let left = document.leftCounts, right = document.rightCounts
        let delta = right.words - left.words
        let leftTitle = document.title(for: .left)
        let rightTitle = document.title(for: .right)
        HStack(spacing: 4) {
            if detail == .full {
                Text(leftTitle).foregroundStyle(.secondary)
                Text(left.words.formatted()).monospacedDigit()
                Text("·").foregroundStyle(.tertiary)
                Text(rightTitle).foregroundStyle(.secondary)
                Text(right.words.formatted()).monospacedDigit()
                Text("words").foregroundStyle(.secondary)
            } else {
                Text(right.words.formatted()).monospacedDigit()
                Text(right.words == 1 ? "word" : "words").foregroundStyle(.secondary)
            }
            if delta != 0, detail != .minimal {
                Text("(\(delta > 0 ? "+" : "−")\(abs(delta).formatted()))")
                    .monospacedDigit()
                    .foregroundStyle(delta > 0 ? DiffPalette.added : DiffPalette.removed)
            }
        }
        .help("""
            \(leftTitle): \(Self.plural(left.words, "word")), \(Self.plural(left.characters, "character")), \(Self.plural(left.lines, "line"))
            \(rightTitle): \(Self.plural(right.words, "word")), \(Self.plural(right.characters, "character")), \(Self.plural(right.lines, "line"))
            """)
    }

    private static func plural(_ n: Int, _ noun: String) -> String {
        "\(n.formatted()) \(noun)\(n == 1 ? "" : "s")"
    }

    // MARK: Diff summary

    private var position: String {
        let total = document.result.hunks.count
        if let current = document.currentHunk { return "Change \(current + 1) of \(total)" }
        return "\(total) change\(total == 1 ? "" : "s")"
    }

    private func chip(_ value: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(value).fontWeight(.semibold).foregroundStyle(color).monospacedDigit()
            Text(label).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Ignore rules

struct IgnoreRulesSheet: View {
    @ObservedObject var document: DiffDocument
    @Environment(\.dismiss) private var dismiss
    @State private var newRule = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ignore differences in…").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Whitespace", isOn: $document.options.ignoreWhitespace)
                Toggle("Letter case", isOn: $document.options.ignoreCase)
                Toggle("Quotation marks (\" ' “ ” ‘ ’)", isOn: $document.options.ignoreQuotes)
                Toggle("Dashes (- – — −)", isOn: $document.options.ignoreDashes)
            }
            Divider()
            Text("Custom rules").font(.headline)
            Text("Words, phrases or characters that should never count as a change.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("e.g. TODO, ©, a version string", text: $newRule)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add).disabled(newRule.isEmpty)
            }
            if document.options.ignoredStrings.isEmpty {
                Text("No custom rules.").font(.callout).foregroundStyle(.tertiary)
            } else {
                List {
                    ForEach(document.options.ignoredStrings, id: \.self) { rule in
                        HStack {
                            Text(rule).font(.body.monospaced())
                            Spacer()
                            Button {
                                document.options.ignoredStrings.removeAll { $0 == rule }
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(minHeight: 90, maxHeight: 180)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func add() {
        let rule = newRule
        guard !rule.isEmpty, !document.options.ignoredStrings.contains(rule) else { return }
        document.options.ignoredStrings.append(rule)
        newRule = ""
    }
}
