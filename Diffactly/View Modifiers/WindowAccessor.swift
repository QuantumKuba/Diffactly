import SwiftUI
import AppKit

/// Applies the chosen appearance to the hosting window.
struct WindowAccessor: NSViewRepresentable {
    var appearance: NSAppearance

    func makeNSView(context: Context) -> NSView {
        let nsView = NSView()
        DispatchQueue.main.async {
            nsView.window?.appearance = appearance
        }
        return nsView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.appearance = appearance
    }
}
