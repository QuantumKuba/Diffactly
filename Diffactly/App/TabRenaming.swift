import AppKit

/// Renaming a tab straight from the tab bar: double-click a tab, or
/// right-click it and choose Rename Tab… (added above AppKit's own items).
/// Window ▸ Rename Tab… (⇧⌘R) does the same for the current tab.
///
/// AppKit has no API for the tab bar, so this finds the tab under the pointer
/// by looking for its tab buttons in the title bar. If a future macOS changes
/// them, clicks just behave as before and the menu command still works.
@MainActor
enum TabRenaming {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            handle(event) ? nil : event
        }
    }

    /// Returns true when the event was used.
    private static func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window, let hit = tabHit(at: event.locationInWindow, in: window) else { return false }
        let isContextClick = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        if isContextClick {
            let menu = hit.button.menu(for: event) ?? NSMenu()
            let item = NSMenuItem(title: "Rename Tab…", action: #selector(RenameTarget.rename(_:)), keyEquivalent: "")
            item.target = RenameTarget.shared
            item.representedObject = hit.window
            menu.insertItem(item, at: 0)
            if menu.items.count > 1 { menu.insertItem(.separator(), at: 1) }
            NSMenu.popUpContextMenu(menu, with: event, for: hit.button)
            return true
        }
        if event.type == .leftMouseDown, event.clickCount == 2 {
            rename(hit.window)
            return true
        }
        return false
    }

    /// Opens the rename sheet for the tab showing `window`.
    static func rename(_ window: NSWindow) {
        guard window.attachedSheet == nil, let document = DocumentRouter.shared.document(for: window) else { return }
        window.makeKeyAndOrderFront(nil)
        document.isRenamingTab = true
    }

    // MARK: Finding the tab under the pointer

    struct TabHit {
        let button: NSView
        let window: NSWindow
    }

    /// The tab at `point` (window coordinates) and the window it shows; nil
    /// off the tab bar, or on a tab's close button or the new-tab button.
    static func tabHit(at point: NSPoint, in window: NSWindow) -> TabHit? {
        guard let frame = window.contentView?.superview, let hit = frame.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let current = view, !isTabButton(current) { view = current.superview }
        guard let button = view else { return nil }
        // The close (×) button inside a tab keeps its own behaviour.
        if hit !== button, hit is NSButton { return nil }
        let buttons = tabButtons(in: frame).sorted {
            $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
        }
        let tabs = window.tabbedWindows ?? [window]
        guard buttons.count == tabs.count, let index = buttons.firstIndex(where: { $0 === button }) else { return nil }
        return TabHit(button: button, window: tabs[index])
    }

    static func tabButtons(in view: NSView) -> [NSView] {
        view.subviews.flatMap { isTabButton($0) ? [$0] : tabButtons(in: $0) }
    }

    private static func isTabButton(_ view: NSView) -> Bool {
        let name = String(describing: type(of: view))
        return name.contains("TabButton") && !name.contains("NewTab")
    }
}

/// The menu item's target (menu items need an object to call).
private final class RenameTarget: NSObject {
    static let shared = RenameTarget()

    @MainActor @objc func rename(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? NSWindow else { return }
        TabRenaming.rename(window)
    }
}
