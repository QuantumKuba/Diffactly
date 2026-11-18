import XCTest
import AppKit
@testable import Diffactly

/// Finding the tab under the pointer in AppKit's tab bar, which renaming from
/// the tab bar (double-click, right-click) depends on.
@MainActor
final class TabRenamingTests: XCTestCase {

    private func window() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 400),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.tabbingMode = .preferred
        w.tabbingIdentifier = "TabRenamingTests"
        w.isReleasedWhenClosed = false
        return w
    }

    func testEachTabButtonMapsToItsWindowAndKeepsItsMenu() throws {
        let a = window(), b = window()
        defer { a.close(); b.close() }
        a.makeKeyAndOrderFront(nil)
        a.addTabbedWindow(b, ordered: .above)
        if a.tabGroup?.isTabBarVisible == false { a.toggleTabBar(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let w = a.tabGroup?.selectedWindow ?? a
        let frame = try XCTUnwrap(w.contentView?.superview)
        let buttons = TabRenaming.tabButtons(in: frame)
            .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        XCTAssertEqual(buttons.count, 2, "AppKit's tab bar changed; renaming from the tab bar needs updating")
        for (i, button) in buttons.enumerated() {
            let r = button.convert(button.bounds, to: nil)
            let hit = TabRenaming.tabHit(at: NSPoint(x: r.midX - 20, y: r.midY), in: w)
            XCTAssertTrue(hit?.window === w.tabbedWindows?[i], "tab \(i)")
        }
        XCTAssertNil(TabRenaming.tabHit(at: NSPoint(x: 350, y: 100), in: w), "a click in the content isn't on a tab")

        let r = buttons[0].convert(buttons[0].bounds, to: nil)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: r.midX, y: r.midY), modifierFlags: [],
                                                     timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertFalse(buttons[0].menu(for: click)?.items.isEmpty ?? true, "the native tab menu is kept under Rename Tab…")
    }
}
