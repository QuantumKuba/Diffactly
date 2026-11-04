import SwiftUI
import AppKit

/// Receives files opened from Finder, the Dock or `diffactly --gui`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in DocumentRouter.shared.open(urls) }
    }
}

/// Delivers opened files to the frontmost Diffactly window (or the first one to appear).
@MainActor
final class DocumentRouter {
    static let shared = DocumentRouter()

    private struct Entry {
        weak var document: DiffDocument?
        weak var window: NSWindow?
    }

    private var entries: [Entry] = []
    private var pending: [[URL]] = []
    private weak var active: DiffDocument?

    func register(_ document: DiffDocument, window: NSWindow) {
        entries.removeAll { $0.document == nil || $0.window == nil }
        if !entries.contains(where: { $0.window === window }) {
            entries.append(Entry(document: document, window: window))
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self, weak document] _ in
                MainActor.assumeIsolated { if let document { self?.active = document } }
            }
        }
        if active == nil || window.isKeyWindow { active = document }
        flush()
    }

    func open(_ urls: [URL]) {
        pending.append(urls)
        flush()
    }

    private func flush() {
        guard let target = active ?? entries.compactMap(\.document).first else { return }
        let batches = pending
        pending.removeAll()
        for urls in batches { target.open(urls) }
        if !batches.isEmpty { NSApp.activate(ignoringOtherApps: true) }
    }
}

/// Reports the hosting NSWindow once the view is attached to it.
struct WindowObserver: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ObservingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ObservingView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { DispatchQueue.main.async { self.onWindow?(window) } }
        }
    }
}
