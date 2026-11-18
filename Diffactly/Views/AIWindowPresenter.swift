import SwiftUI
import AppKit

/// Presents `RewriteSheet` in a non-modal auxiliary window for one tab, so the
/// user can keep editing the tab name, pane titles, or texts while AI thinking
/// and generation run asynchronously in the background.
struct AIWindowPresenter: NSViewRepresentable {
    @Binding var isPresented: Bool
    var isRenamingTab: Bool
    var requestID: UUID
    var title: String
    var appearance: NSAppearance
    var document: DiffDocument
    var session: RewriteSession

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented, document: document, session: session)
    }

    func makeNSView(context: Context) -> NSView {
        let view = ObservingView()
        let coordinator = context.coordinator
        view.onWindow = { [weak coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.isPresented = $isPresented
        if let window = nsView.window {
            coordinator.attach(to: window)
        }
        coordinator.sync(
            isPresented: isPresented,
            isRenamingTab: isRenamingTab,
            requestID: requestID,
            title: title,
            appearance: appearance
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.tearDown(stopSession: true)
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var isPresented: Binding<Bool>
        private let document: DiffDocument
        private let session: RewriteSession

        private weak var parentWindow: NSWindow?
        private(set) var aiWindow: NSWindow?
        private var parentCloseObserver: NSObjectProtocol?
        private var lastPresented = false
        private var lastRenamingTab = false
        private var lastRequestID: UUID?
        private var isSyncingFromWindow = false

        init(isPresented: Binding<Bool>, document: DiffDocument, session: RewriteSession) {
            self.isPresented = isPresented
            self.document = document
            self.session = session
        }

        func attach(to window: NSWindow) {
            guard parentWindow !== window else { return }
            if let observer = parentCloseObserver {
                NotificationCenter.default.removeObserver(observer)
                parentCloseObserver = nil
            }
            parentWindow = window
            if let aiWindow {
                WindowTabs.registerAuxiliary(aiWindow, for: window)
            }
            parentCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.tearDown(stopSession: true)
                }
            }
        }

        func sync(
            isPresented presented: Bool,
            isRenamingTab: Bool,
            requestID: UUID,
            title: String,
            appearance: NSAppearance
        ) {
            // If the user triggered "Rename Tab…" while the AI window was key,
            // bring the tab window forward so the rename sheet has focus.
            if isRenamingTab && !lastRenamingTab {
                parentWindow?.makeKeyAndOrderFront(nil)
            }
            lastRenamingTab = isRenamingTab

            if presented {
                let window = ensureWindow(title: title, appearance: appearance)
                if window.title != title { window.title = title }
                if window.appearance != appearance { window.appearance = appearance }
                if !lastPresented || lastRequestID != requestID || !window.isVisible {
                    lastRequestID = requestID
                    window.makeKeyAndOrderFront(nil)
                }
            } else if lastPresented, !isSyncingFromWindow, let window = aiWindow, window.isVisible {
                let wasKey = window.isKeyWindow
                window.orderOut(nil)
                if wasKey { parentWindow?.makeKeyAndOrderFront(nil) }
            }
            lastPresented = presented
        }

        private func ensureWindow(title: String, appearance: NSAppearance) -> NSWindow {
            if let aiWindow { return aiWindow }

            let root = AIWindowRootView(document: document, session: session) { [weak self] in
                self?.hideFromUI()
            }
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.tabbingMode = .disallowed
            window.isReleasedWhenClosed = false
            window.title = title
            window.appearance = appearance
            window.minSize = NSSize(width: 740, height: 420)
            window.setContentSize(NSSize(width: 940, height: 640))
            window.delegate = self
            position(window, relativeTo: parentWindow)

            if let parentWindow {
                WindowTabs.registerAuxiliary(window, for: parentWindow)
            }
            aiWindow = window
            return window
        }

        private func position(_ window: NSWindow, relativeTo parent: NSWindow?) {
            guard let parent else {
                window.center()
                return
            }
            let parentFrame = parent.frame
            var frame = window.frame
            frame.origin.x = parentFrame.midX - frame.width / 2
            frame.origin.y = parentFrame.midY - frame.height / 2
            if let visible = (parent.screen ?? NSScreen.main)?.visibleFrame {
                frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
                frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
            }
            window.setFrameOrigin(frame.origin)
        }

        private func hideFromUI() {
            guard isPresented.wrappedValue else { return }
            isPresented.wrappedValue = false
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            isSyncingFromWindow = true
            isPresented.wrappedValue = false
            isSyncingFromWindow = false
            lastPresented = false
            let wasKey = sender.isKeyWindow
            sender.orderOut(nil)
            if wasKey { parentWindow?.makeKeyAndOrderFront(nil) }
            return false
        }

        func tearDown(stopSession: Bool) {
            if let observer = parentCloseObserver {
                NotificationCenter.default.removeObserver(observer)
                parentCloseObserver = nil
            }
            if stopSession {
                session.stop()
            }
            if let window = aiWindow {
                WindowTabs.unregisterAuxiliary(window)
                window.delegate = nil
                window.orderOut(nil)
                window.close()
                aiWindow = nil
            }
            if isPresented.wrappedValue {
                isSyncingFromWindow = true
                isPresented.wrappedValue = false
                isSyncingFromWindow = false
            }
            lastPresented = false
        }
    }

    private final class ObservingView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                onWindow?(window)
            }
        }
    }
}

private struct AIWindowRootView: View {
    @ObservedObject var document: DiffDocument
    @ObservedObject var session: RewriteSession
    @ObservedObject private var appearanceManager = AppearanceManager.shared
    let onClose: () -> Void

    var body: some View {
        RewriteSheet(document: document, session: session, onDismiss: onClose)
            .preferredColorScheme(appearanceManager.effectiveColorScheme)
            .focusedSceneObject(document)
    }
}
