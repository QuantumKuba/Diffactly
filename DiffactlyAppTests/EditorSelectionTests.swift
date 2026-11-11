import XCTest
import SwiftUI
import AppKit
@testable import Diffactly

/// Hosts the real `CodeEditor` in a window and drives its text view, so the
/// selection plumbing (NSTextView delegate → callback) is exercised without UI automation.
@MainActor
final class EditorSelectionTests: XCTestCase {

    private final class Box { var values: [String] = [] }

    private func findTextView(in view: NSView) -> DiffTextView? {
        if let tv = view as? DiffTextView { return tv }
        for sub in view.subviews { if let found = findTextView(in: sub) { return found } }
        return nil
    }

    private func settle() async {
        // The editor hops one main-queue turn before reporting.
        for _ in 0..<5 { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    private func makeHostedEditor(text: String, onSelectionChange: @escaping (String) -> Void) -> (NSWindow, DiffTextView)? {
        makeHostedEditor(text: text, onSelection: { text, _ in onSelectionChange(text) })
    }

    private func makeHostedEditor(text: String, onSelection: @escaping (String, NSRange) -> Void) -> (NSWindow, DiffTextView)? {
        let editor = CodeEditor(
            text: .constant(text),
            highlights: EditorHighlights(),
            placeholder: "",
            wrapLines: true,
            focusRequest: nil,
            focusLines: nil,
            onFileDrop: { _ in },
            onSelectionChange: onSelection
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let textView = findTextView(in: host) else { return nil }
        return (window, textView)
    }

    func testEditorReportsTheSelectedText() async throws {
        let box = Box()
        let (window, textView) = try XCTUnwrap(makeHostedEditor(text: "alpha beta gamma", onSelectionChange: { box.values.append($0) }))
        withExtendedLifetime(window) {}

        textView.setSelectedRange(NSRange(location: 6, length: 4))
        await settle()
        XCTAssertEqual(box.values.last, "beta")

        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
        await settle()
        XCTAssertEqual(box.values.last, "alpha beta gamma")
    }

    func testCollapsingTheSelectionReportsEmptyText() async throws {
        let box = Box()
        let (window, textView) = try XCTUnwrap(makeHostedEditor(text: "alpha beta gamma", onSelectionChange: { box.values.append($0) }))
        withExtendedLifetime(window) {}

        textView.setSelectedRange(NSRange(location: 0, length: 5))
        await settle()
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        await settle()
        XCTAssertEqual(box.values.last, "")
    }

    func testSelectionFlowsIntoTheDocumentCounts() async throws {
        let document = DiffDocument(left: "x", right: "alpha beta gamma delta")
        document.mode = .edit
        // Same wiring ContentView uses for the "Changed" editor.
        let (window, textView) = try XCTUnwrap(makeHostedEditor(text: document.rightText) {
            document.updateSelection(side: .right, selectedText: $0)
        })
        withExtendedLifetime(window) {}

        textView.setSelectedRange(NSRange(location: 0, length: 16))   // "alpha beta gamma"
        await settle()
        XCTAssertEqual(document.selection?.side, .right)
        XCTAssertEqual(document.selection?.counts.words, 3)
        XCTAssertEqual(document.selection?.counts.characters, 16)
    }
}
