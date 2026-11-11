import SwiftUI
import AppKit

/// Ghostty-style tabs on top of native macOS window tabbing: every tab is its own
/// comparison window, merged into the tab group of the window it was opened from.
@MainActor
enum WindowTabs {
    static let windowID = "comparison"

    /// The window a requested tab should join, until that tab's window appears.
    private static weak var pendingHost: NSWindow?

    /// The comparison window the user is working in (a sheet's parent rather than the sheet).
    static var currentWindow: NSWindow? {
        let window = NSApp.mainWindow ?? NSApp.keyWindow
        return window?.sheetParent ?? window
    }

    /// Windows in the current tab group, in tab-bar order.
    static var currentTabs: [NSWindow] {
        guard let window = currentWindow else { return [] }
        return window.tabbedWindows ?? [window]
    }

    static func newTab(using openWindow: OpenWindowAction) {
        pendingHost = currentWindow
        openWindow(id: windowID)
    }

    /// Called as soon as a comparison window's content is attached to it.
    static func adopt(_ window: NSWindow) {
        guard let host = pendingHost, host !== window, host.isVisible else { return }
        pendingHost = nil
        host.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }

    private static let tabBarShownByDefaultKey = "TabBarShownByDefault"

    /// Shows the tab bar even for a single tab — one wide tab with the "+" beside it —
    /// so tabs are discoverable without knowing ⌘T. This happens once: from then on
    /// AppKit itself remembers View ▸ Show/Hide Tab Bar, so hiding it sticks.
    static func showTabBar(in window: NSWindow) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: tabBarShownByDefaultKey), let group = window.tabGroup else { return }
        if !group.isTabBarVisible { window.toggleTabBar(nil) }
        defaults.set(true, forKey: tabBarShownByDefaultKey)
    }

    /// ⌘1…⌘8 pick that tab, ⌘9 always the last one (as in Ghostty and Safari).
    static func selectTab(number: Int) {
        let tabs = currentTabs
        guard !tabs.isEmpty else { return }
        let index = number >= 9 ? tabs.count - 1 : number - 1
        guard tabs.indices.contains(index) else { return }
        tabs[index].makeKeyAndOrderFront(nil)
    }

    static func selectNextTab() { currentWindow?.selectNextTab(nil) }
    static func selectPreviousTab() { currentWindow?.selectPreviousTab(nil) }
}

struct TabCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedObject private var document: DiffDocument?

    var body: some Commands {
        CommandGroup(before: .newItem) {
            Button("New Tab") { WindowTabs.newTab(using: openWindow) }
                .keyboardShortcut("t")
        }

        CommandGroup(before: .windowList) {
            Button("Rename Tab…") { document?.isRenamingTab = true }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(document == nil)
            Divider()
            Button("Select Previous Tab") { WindowTabs.selectPreviousTab() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Select Next Tab") { WindowTabs.selectNextTab() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Menu("Select Tab") {
                ForEach(1...9, id: \.self) { number in
                    Button(number == 9 ? "Last Tab" : "Tab \(number)") { WindowTabs.selectTab(number: number) }
                        .keyboardShortcut(KeyEquivalent(Character("\(number)")))
                }
            }
            Divider()
        }
    }
}

/// Names the current tab; an empty name goes back to the automatic one.
struct RenameTabSheet: View {
    @ObservedObject var document: DiffDocument
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Tab").font(.title3.weight(.semibold))
            TextField(document.automaticTabTitle, text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)
            Text("Leave empty to name the tab after the open files.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            draft = document.tabTitle
            focused = true
        }
    }

    private func commit() {
        document.setTabTitle(draft)
        dismiss()
    }
}
