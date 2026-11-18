import SwiftUI
import AppKit
import DiffactlyCore

struct ContentView: View {
    @StateObject private var document = DiffDocument()
    @StateObject private var rewrite = RewriteSession()
    @State private var showIgnoreRules = false
    /// The tab's custom name survives relaunches along with the window.
    @SceneStorage("tabTitle") private var storedTabTitle = ""
    /// The saved session tab this window shows, so it shows it again after a relaunch.
    @SceneStorage("sessionTab") private var storedSessionTab = ""
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch document.mode {
                case .edit:
                    HStack(spacing: 0) {
                        EditorPane(document: document, session: rewrite, side: .left)
                        Divider()
                        EditorPane(document: document, session: rewrite, side: .right)
                    }
                case .split, .unified:
                    DiffOutputView(document: document, layout: document.mode)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let anchor = document.pendingLink { PendingLinkBar(document: document, anchor: anchor) }
            }
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
            .safeAreaInset(edge: .trailing, spacing: 0) {
                if document.isShowingComments { CommentsSidebar(document: document) }
            }
            Divider()
            StatusBar(document: document)
        }
        .frame(minWidth: 760, minHeight: 440)
        .toolbar { DiffToolbar(document: document, showIgnoreRules: $showIgnoreRules) }
        .inspector(isPresented: $document.showInsights) {
            InsightsPanel(document: document)
                .inspectorColumnWidth(min: 260, ideal: 310, max: 460)
        }
        .navigationTitle(document.displayTabTitle)
        .navigationSubtitle(subtitle)
        .focusedSceneObject(document)
        .background(WindowObserver(onAttach: WindowTabs.adopt) { window in
            connect()
            DocumentRouter.shared.register(document, window: window)
            WindowTabs.showTabBar(in: window)
            SessionController.shared.documentAppeared(document, window: window, restoring: storedSessionTab)
        })
        .sheet(isPresented: $showIgnoreRules) { IgnoreRulesSheet(document: document) }
        .sheet(isPresented: $document.isRenamingTab) { RenameTabSheet(document: document) }
        .sheet(isPresented: $document.isShowingAI) { RewriteSheet(document: document, session: rewrite) }
        .sheet(item: $document.comparedSuggestion) { SuggestionCompareSheet(document: document, suggestion: $0) }
        .onAppear {
            if document.tabTitle.isEmpty { document.tabTitle = storedTabTitle }
            connect()
        }
        .onChange(of: document.sessionMarker) { _, marker in storedSessionTab = marker }
        .onChange(of: document.projectFolder, initial: true) { _, folder in rewrite.references.setProjectFolder(folder) }
        .onChange(of: document.tabTitle) { _, title in storedTabTitle = title }
        .alert("Couldn’t open file", isPresented: Binding(get: { document.errorMessage != nil }, set: { if !$0 { document.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(document.errorMessage ?? "")
        }
    }

    /// Ties the window's AI sheet to its document. Done before the window
    /// reports itself too, since a saved session restores both together.
    private func connect() {
        guard document.rewriteSession !== rewrite else { return }
        rewrite.references.owner = document
        document.rewriteSession = rewrite
        document.suggestionHandler = rewrite.suggestionHandler(for: document)
        SessionController.shared.provide(openWindow)
    }

    /// The session and the open files (unless the title already shows them).
    private var subtitle: String {
        var parts: [String] = []
        if let session = document.projectSession { parts.append(session.name) }
        if let files = document.fileSummary, files != document.displayTabTitle { parts.append(files) }
        return parts.joined(separator: " — ")
    }
}

// MARK: - Linking

/// Shown while one end of a link is picked: what's picked, and what to do
/// next to finish it.
private struct PendingLinkBar: View {
    @ObservedObject var document: DiffDocument
    let anchor: PendingLinkEnd

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "link").foregroundStyle(DiffPalette.link)
            Text("Linking “\(snippet)” in \(document.title(for: anchor.side)). Select the text that says the same in \(document.title(for: anchor.side.other)), then press ⌥⌘L.")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if document.mode != .edit {
                Button("Show Editors") { document.mode = .edit }
            }
            Button("Cancel") { document.cancelPendingLink() }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(DiffPalette.link.opacity(0.10))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var snippet: String {
        let text = anchor.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return text.count > 48 ? String(text.prefix(46)) + "…" : text
    }
}

// MARK: - Editor pane

struct EditorPane: View {
    @ObservedObject var document: DiffDocument
    /// Not observed: the editor only needs its settings when asking for a suggestion.
    let session: RewriteSession
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
                    document.clear(side)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .disabled(document.isEmpty(side))
                .help("Clear the \(document.title(for: side).lowercased()) text (⌘K clears the focused side, ⇧⌘K both)")
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
                onSelectionChange: { selected, range in document.updateSelection(side: side, selectedText: selected, range: range) },
                selectionRequest: document.selectionRequest,
                onRewriteSelection: { selected, range in
                    document.updateSelection(side: side, selectedText: selected, range: range)
                    document.showAI(.rewrite, selection: true)
                },
                onSuggestRewrite: { selected, range in
                    document.updateSelection(side: side, selectedText: selected, range: range)
                    session.suggest(side: side, range: range, text: selected, document: document, store: .shared,
                                    showingOptions: RewriteSession.showsOptionsFirst)
                },
                onSuggestRewriteWithOptions: { selected, range in
                    document.updateSelection(side: side, selectedText: selected, range: range)
                    session.suggest(side: side, range: range, text: selected, document: document, store: .shared, showingOptions: true)
                },
                quickRewriteTitle: RewriteSession.currentPromptName,
                suggestionMarks: document.suggestionMarks(for: side),
                presentedSuggestion: document.presentedSuggestion,
                onPresentSuggestion: { id, pinned in document.presentSuggestion(id, pinned: pinned) },
                onSuggestionCardClosed: { id in document.suggestionCardClosed(id) },
                suggestionCard: { id in AnyView(SuggestionCardHost(document: document, session: session, id: id)) },
                sourceMarks: document.sourceMarks(for: side).map(\.range),
                totalSourceMarks: document.sourceMarks.count,
                onSourceMarkAction: { action in document.handle(action, on: side) },
                linkMarks: document.linkMarks(for: side),
                isLinkPendingOnOtherSide: document.pendingLink?.side == side.other,
                otherSideTitle: document.title(for: side.other),
                onLinkAction: { action in document.handle(action, on: side) },
                onLinkHover: { id in
                    if id != nil || document.hoveredLinkID != nil { document.hoveredLinkID = id }
                },
                commentMarks: document.commentMarks(for: side),
                presentedComment: document.presentedComment,
                onPresentComment: { id, pinned in document.presentComment(id, pinned: pinned) },
                onCommentClosed: { id in document.commentCardClosed(id) },
                commentCard: { id in AnyView(CommentCardHost(document: document, id: id)) },
                onAddComment: { _, range in document.addComment(side: side, range: range) },
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
            if !document.suggestions.isEmpty {
                suggestionsMenu(detail)
            }
            if !document.sourceMarks.isEmpty {
                sourceMarksMenu(detail)
            }
            if !document.comments.isEmpty {
                CommentsStatusItem(document: document, compact: detail == .minimal)
            }
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

    // MARK: AI suggestions

    /// "✦ 2 suggestions": jump between them, or accept / reject them all.
    private func suggestionsMenu(_ detail: Detail) -> some View {
        let all = document.suggestions
        let ready = all.filter(\.isReady).count
        let running = all.filter { $0.status.isRunning }.count
        let title = detail == .minimal ? "\(all.count)" : "\(all.count) suggestion\(all.count == 1 ? "" : "s")"
        return Menu {
            Button("Show Next Suggestion") { document.presentNextSuggestion() }
            Divider()
            Button("Accept All Ready (\(ready))") { document.acceptAllSuggestions() }
                .disabled(ready == 0)
            Button("Reject All", role: .destructive) { document.rejectAllSuggestions() }
        } label: {
            Label(title, systemImage: running > 0 ? "sparkles" : "sparkle")
                .foregroundStyle(DiffPalette.suggestion)
        } primaryAction: {
            document.presentNextSuggestion()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(running > 0
              ? "AI suggestions: \(running) being written, \(ready) ready to review. Click to show the next."
              : "AI suggestions waiting for review. Click to show the next one, or use the menu to accept or reject them all.")
    }

    // MARK: AI source highlights

    /// "⌇ 2 highlighted": jump between them, or clear them.
    private func sourceMarksMenu(_ detail: Detail) -> some View {
        let count = document.sourceMarks.count
        let title = detail == .minimal ? "\(count)" : "\(count) highlighted"
        return Menu {
            Button("Show Next Highlight") { document.revealNextSourceMark() }
            Divider()
            ForEach([DiffDocument.Side.left, .right], id: \.self) { side in
                let n = document.sourceMarks(for: side).count
                Button("Clear \(document.title(for: side)) Highlights (\(n))") { document.clearSourceMarks(on: side) }
                    .disabled(n == 0)
            }
            Button("Clear All Highlights", role: .destructive) { document.clearSourceMarks() }
        } label: {
            Label(title, systemImage: "highlighter")
                .foregroundStyle(DiffPalette.sourceMark)
        } primaryAction: {
            document.revealNextSourceMark()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Text highlighted as a source for AI rewrites: a passage rewrite in one editor takes the highlighted text in the other as its counterpart. Click to show the next one.")
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
