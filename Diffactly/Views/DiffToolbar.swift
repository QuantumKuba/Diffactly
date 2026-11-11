import SwiftUI
import AppKit
import DiffactlyCore

struct DiffToolbar: ToolbarContent {
    @ObservedObject var document: DiffDocument
    @Binding var showIgnoreRules: Bool

    var body: some ToolbarContent {
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
                Button("Rewrite with AI…") { document.showAI(.rewrite) }
                Button("Rewrite Selection with AI…") { document.showAI(.rewrite, selection: true) }
                    .disabled(document.selection == nil)
                Button("Summarize Differences with AI…") { document.showAI(.summary) }
            } label: {
                Label("AI", systemImage: "sparkles")
            } primaryAction: {
                document.showAI(.rewrite)
            }
            .help("Humanize, paraphrase or merge the texts (⌥⌘R), rewrite just the selection (⌥⌘E), or summarize the main differences (⇧⌥⌘R)")

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
            Button("Rewrite with AI…") { document?.showAI(.rewrite) }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(document == nil)
            Button("Rewrite Selection with AI…") { document?.showAI(.rewrite, selection: true) }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(document?.selection == nil)
            Button("Summarize Differences with AI…") { document?.showAI(.summary) }
                .keyboardShortcut("r", modifiers: [.command, .option, .shift])
                .disabled(document == nil)
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
