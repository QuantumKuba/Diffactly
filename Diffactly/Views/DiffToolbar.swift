import SwiftUI
import AppKit
import DiffactlyCore

struct DiffToolbar: ToolbarContent {
    @ObservedObject var document: DiffDocument
    @Binding var showIgnoreRules: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            SessionMenu(document: document)
        }

        ToolbarItem(placement: .navigation) {
            Picker("View", selection: $document.mode) {
                ForEach(DiffDocument.Mode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleAndIcon)
            .help("Edit the inputs, or view the aligned comparison side by side or unified (⌃⌘1–3)")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Precision", selection: $document.options.level) {
                ForEach(DiffLevel.allCases) { level in Text(level.title).tag(level) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("How finely changes inside a line are highlighted")

            Menu {
                OptionToggles(document: document)
                Divider()
                Button("Ignore Rules…") { showIgnoreRules = true }
            } label: {
                Label("Options", systemImage: optionsActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .help("Ignore whitespace, case, quotes, dashes or custom strings")

            Menu {
                ForEach(TextTransform.allCases) { t in
                    Button(t.title) { document.apply(t) }
                }
            } label: {
                Label("Transform", systemImage: "wand.and.stars")
            }
            .help("Transform both texts (undoable)")

            Menu {
                Button("\(RewriteSession.currentPromptName) Selection") { document.suggestRewriteForSelection() }
                    .disabled(document.selection == nil)
                Button("\(RewriteSession.currentPromptName) Selection with Options…") { document.suggestRewriteForSelection(withOptions: true) }
                    .disabled(document.selection == nil)
                Button(document.selection == nil ? "Rewrite with AI…" : "Rewrite Selection with AI…") { document.showAI(.rewrite) }
                Button("Summarize Differences with AI…") { document.showAI(.summary) }
                if !document.suggestions.isEmpty {
                    Divider()
                    Button("Show Next Suggestion") { document.presentNextSuggestion() }
                    Button("Accept All Ready Suggestions") { document.acceptAllSuggestions() }
                    Button("Reject All Suggestions") { document.rejectAllSuggestions() }
                }
            } label: {
                Label("AI", systemImage: "sparkles")
            } primaryAction: {
                document.showAI(.rewrite)
            }
            .help("With text selected: suggest a rewrite of just the selection to accept or reject (⌥⌘E; ⌥⇧⌘E to choose its settings first), or open the AI panel on it (⌥⌘R). Without: humanize, paraphrase or merge whole texts, or summarize the differences (⇧⌥⌘R).")

            Button {
                document.swapSides()
            } label: {
                Label("Swap", systemImage: "arrow.left.arrow.right")
            }
            .help("Swap original and changed")

            ControlGroup {
                Button { document.previousChange() } label: { Label("Previous Change", systemImage: "chevron.up") }
                    .help("Previous change (⌃⌘↑)")
                Button { document.nextChange() } label: { Label("Next Change", systemImage: "chevron.down") }
                    .help("Next change (⌃⌘↓)")
            }
            .disabled(!document.hasChanges)

            Button {
                if document.search.isPresented {
                    document.closeSearch()
                } else {
                    document.openSearch()
                }
            } label: {
                Label("Find", systemImage: document.search.isPresented ? "magnifyingglass.circle.fill" : "magnifyingglass")
            }
            .help("Find text (⌘F)")

            Toggle(isOn: $document.showInsights) {
                Label("Insights", systemImage: "chart.bar.xaxis")
            }
            .help("Show graphs about this comparison (⌥⌘I)")

            TitleBarAccessory()
        }
    }

    private var optionsActive: Bool {
        let o = document.options
        return o.ignoreWhitespace || o.ignoreCase || o.ignoreQuotes || o.ignoreDashes || !o.ignoredStrings.isEmpty
    }
}

/// Toolbar menu for sessions: open one (or a recent one), save this window's
/// tabs as one, or find the current one in Finder. Clicking the button itself
/// shows the open panel.
struct SessionMenu: View {
    @ObservedObject var document: DiffDocument
    @ObservedObject private var sessions = SessionController.shared

    var body: some View {
        Menu {
            Button("Open Session…") { sessions.showOpenPanel() }
            Section("Recent Sessions") {
                if sessions.recents.isEmpty {
                    Text("No Recent Sessions")
                } else {
                    ForEach(sessions.recents) { recent in
                        Button(sessions.menuTitle(for: recent)) { sessions.openRecent(recent) }
                    }
                }
            }
            Divider()
            Button(document.projectSession == nil ? "Save Session…" : "Save Session") { sessions.save(from: document) }
            Button("Save Session As…") { sessions.saveAs(from: document) }
            Button("Show Session in Finder") { sessions.showInFinder(document) }
                .disabled(document.projectSession == nil)
            if !sessions.recents.isEmpty {
                Divider()
                Button("Clear Recent Sessions") { sessions.clearRecents() }
            }
        } label: {
            Label(document.projectSession?.name ?? "Sessions", systemImage: "square.stack.3d.up")
        } primaryAction: {
            sessions.showOpenPanel()
        }
        .help(document.projectSession.map { "Session “\($0.name)”: open, save or switch sessions (⌥⌘O opens one)" }
              ?? "Open a saved session or a recent one, or save this window’s tabs as a session (⌥⌘O, ⌘S)")
    }
}

struct OptionToggles: View {
    @ObservedObject var document: DiffDocument

    var body: some View {
        Toggle("Ignore Whitespace", isOn: $document.options.ignoreWhitespace)
        Toggle("Ignore Case", isOn: $document.options.ignoreCase)
        Toggle("Ignore Quote Style", isOn: $document.options.ignoreQuotes)
        Toggle("Ignore Dash Style", isOn: $document.options.ignoreDashes)
        Divider()
        Toggle("Detect Moved Lines", isOn: $document.options.detectMoves)
        Toggle("Collapse Unchanged Lines", isOn: $document.collapseUnchanged)
        Toggle("Wrap Lines", isOn: $document.wrapLines)
    }
}

// MARK: - Menu bar commands

struct DiffCommands: Commands {
    @FocusedObject private var document: DiffDocument?

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("Open \(document?.title(for: .left) ?? "Original")…") { document?.showOpenPanel(for: .left) }
                .keyboardShortcut("o")
                .disabled(document == nil)
            Button("Open \(document?.title(for: .right) ?? "Changed")…") { document?.showOpenPanel(for: .right) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(document == nil)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy as Unified Diff") {
                guard let patch = document?.unifiedPatch else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(patch, forType: .string)
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(document?.hasChanges != true)
        }

        CommandMenu("Find") {
            Button("Find…") {
                document?.openSearch()
            }
            .keyboardShortcut("f")
            .disabled(document == nil)

            Button("Find Next") {
                document?.findNext()
            }
            .keyboardShortcut("g")
            .disabled(document == nil || document?.search.matches.isEmpty != false)

            Button("Find Previous") {
                document?.findPrevious()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(document == nil || document?.search.matches.isEmpty != false)

            Button("Use Selection for Find") {
                document?.useSelectionForSearch()
            }
            .keyboardShortcut("e")
            .disabled(document == nil)
        }

        CommandMenu("Compare") {
            ForEach(Array(DiffDocument.Mode.allCases.enumerated()), id: \.element) { index, mode in
                Button(mode == .edit ? "Edit Inputs" : "\(mode.title) View") { document?.mode = mode }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .control])
            }
            Divider()
            Button("Next Change") { document?.nextChange() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .control])
                .disabled(document?.hasChanges != true)
            Button("Previous Change") { document?.previousChange() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])
                .disabled(document?.hasChanges != true)
            Divider()
            Picker("Precision", selection: binding(\.options.level, default: .smart)) {
                ForEach(DiffLevel.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Ignore Whitespace", isOn: binding(\.options.ignoreWhitespace, default: false))
            Toggle("Ignore Case", isOn: binding(\.options.ignoreCase, default: false))
            Toggle("Ignore Quote Style", isOn: binding(\.options.ignoreQuotes, default: false))
            Toggle("Ignore Dash Style", isOn: binding(\.options.ignoreDashes, default: false))
            Toggle("Detect Moved Lines", isOn: binding(\.options.detectMoves, default: true))
            Divider()
            Menu("Transform Text") {
                ForEach(TextTransform.allCases) { t in Button(t.title) { document?.apply(t) } }
            }
            Button("Swap Sides") { document?.swapSides() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("\(RewriteSession.currentPromptName) Selection") { document?.suggestRewriteForSelection() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(document?.selection == nil)
            Button("\(RewriteSession.currentPromptName) Selection with Options…") { document?.suggestRewriteForSelection(withOptions: true) }
                .keyboardShortcut("e", modifiers: [.command, .option, .shift])
                .disabled(document?.selection == nil)
            Button(document?.selection == nil ? "Rewrite with AI…" : "Rewrite Selection with AI…") { document?.showAI(.rewrite) }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(document == nil)
            Button("Summarize Differences with AI…") { document?.showAI(.summary) }
                .keyboardShortcut("r", modifiers: [.command, .option, .shift])
                .disabled(document == nil)
            Button(document?.selectionIsSourceMarked == true ? "Remove AI Source Highlight" : "Use Selection as AI Source") { document?.toggleSourceMarkForSelection() }
                .keyboardShortcut("u", modifiers: [.command, .option])
                .disabled(document?.selection == nil)
            Button("Clear AI Source Highlights") { document?.clearSourceMarks() }
                .disabled(document?.sourceMarks.isEmpty != false)
            Button(document?.pendingLink == nil ? "Link Selection to Other Side" : "Link to Picked Text") { document?.linkSelection() }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(document?.selection == nil)
            Button("Remove All Links") { document?.removeAllLinks() }
                .disabled(document?.links.isEmpty != false)
            Button("Forget AI Rewrite History") { document?.forgetAllRewrites() }
                .disabled(document?.acceptedRewrites.isEmpty != false)
            Button("Show Next AI Suggestion") { document?.presentNextSuggestion() }
                .keyboardShortcut("'", modifiers: [.command, .option])
                .disabled(document?.suggestions.isEmpty != false)
            Button("Accept All AI Suggestions") { document?.acceptAllSuggestions() }
                .disabled(document?.suggestions.contains(where: \.isReady) != true)
            Button("Reject All AI Suggestions") { document?.rejectAllSuggestions() }
                .disabled(document?.suggestions.isEmpty != false)
            Divider()
            Button("Clear \(document.map { $0.title(for: $0.sideToClear) } ?? "Original")") {
                guard let document else { return }
                document.clear(document.sideToClear)
            }
            .keyboardShortcut("k")
            .disabled(document.map { $0.isEmpty($0.sideToClear) } ?? true)
            Button("Clear Both") { document?.clearAll() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(document.map { $0.isEmpty(.left) && $0.isEmpty(.right) } ?? true)
            Divider()
            Toggle("Collapse Unchanged Lines", isOn: binding(\.collapseUnchanged, default: false))
            Toggle("Wrap Lines", isOn: binding(\.wrapLines, default: true))
            Toggle("Show Insights", isOn: binding(\.showInsights, default: false))
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }

    private func binding<T>(_ keyPath: ReferenceWritableKeyPath<DiffDocument, T>, default value: T) -> Binding<T> {
        Binding(
            get: { document?[keyPath: keyPath] ?? value },
            set: { document?[keyPath: keyPath] = $0 }
        )
    }
}
