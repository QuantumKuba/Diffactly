import XCTest
import SwiftUI
import AppKit
import DiffactlyCore
@testable import Diffactly

@MainActor
final class AsyncAIWorkflowTests: XCTestCase {

    // MARK: Mock streaming URLProtocol

    private final class MockStreamProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: ((URLRequest, MockStreamProtocol) -> Void)?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.handler?(request, self)
        }

        override func stopLoading() {}

        func sendHeader(status: Int = 200) {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }

        func sendSSE(_ json: String) {
            let line = "data: \(json)\n\n"
            client?.urlProtocol(self, didLoad: Data(line.utf8))
        }

        func finishSSE() {
            client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockStreamProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeEphemeralDefaults() -> UserDefaults {
        let suite = "AsyncAIWorkflowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    override func tearDown() {
        MockStreamProtocol.handler = nil
        super.tearDown()
    }

    // MARK: Tests

    func testTabAndDocumentEditsSucceedWhileAIActivelyThinksInNonModalWindow() async throws {
        let thinkingStarted = expectation(description: "AI stream started thinking")
        var activeProtocol: MockStreamProtocol?
        MockStreamProtocol.handler = { _, proto in
            activeProtocol = proto
            proto.sendHeader()
            proto.sendSSE(#"{"choices":[{"delta":{"reasoning_content":"Thinking about phrasing..."}}]}"#)
            thinkingStarted.fulfill()
        }

        let doc = DiffDocument(left: "Original draft.", right: "Updated draft.")
        let store = AIStore(persists: false)
        var provider = AIProvider(kind: .oMLX)
        provider.model = "test-model"
        store.providers = [provider]

        let session = RewriteSession(urlSession: makeMockSession(), defaults: makeEphemeralDefaults())
        session.secondPass = .off
        session.providerID = provider.id

        // Present the non-modal AI window attached to a parent tab window.
        let parentWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let coordinator = AIWindowPresenter.Coordinator(
            isPresented: Binding(get: { doc.isShowingAI }, set: { doc.isShowingAI = $0 }),
            document: doc,
            session: session
        )
        coordinator.attach(to: parentWindow)

        doc.showAI(.rewrite)
        coordinator.sync(
            isPresented: doc.isShowingAI,
            isRenamingTab: doc.isRenamingTab,
            requestID: doc.aiRequestID,
            title: "AI — \(doc.displayTabTitle)",
            appearance: NSAppearance(named: .aqua)!
        )

        // Start AI thinking/rewriting.
        session.run(document: doc, store: store)
        await fulfillment(of: [thinkingStarted], timeout: 2.0)

        for _ in 0..<100 where !session.isThinking {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(session.phase.isRunning)
        XCTAssertTrue(session.isThinking)

        // While the model is actively thinking:
        // 1. Hiding/closing the AI window does NOT cancel the running task.
        let aiWindow = try XCTUnwrap(coordinator.aiWindow)
        XCTAssertFalse(coordinator.windowShouldClose(aiWindow))
        XCTAssertFalse(doc.isShowingAI)
        XCTAssertTrue(session.phase.isRunning, "closing the AI window leaves thinking/generation running")

        // 2. User can rename the tab and edit pane titles & text immediately.
        doc.isRenamingTab = true
        doc.setTabTitle("Edited While Thinking")
        doc.isRenamingTab = false
        doc.setTitle("Before", for: .left)
        doc.leftText = "Original draft with live edit."

        XCTAssertEqual(doc.displayTabTitle, "Edited While Thinking")
        XCTAssertEqual(doc.title(for: .left), "Before")

        // 3. Re-opening the AI window updates its title to the new tab name and preserves the running task.
        doc.showAI(.summary)
        session.prepare(for: doc)
        XCTAssertEqual(session.task, .rewrite, "re-opening while running keeps the active task")
        coordinator.sync(
            isPresented: doc.isShowingAI,
            isRenamingTab: doc.isRenamingTab,
            requestID: doc.aiRequestID,
            title: "AI — \(doc.displayTabTitle)",
            appearance: NSAppearance(named: .aqua)!
        )
        XCTAssertEqual(aiWindow.title, "AI — Edited While Thinking")

        // Finish the streamed answer and verify it completes cleanly.
        activeProtocol?.sendSSE(#"{"choices":[{"delta":{"content":"Polished rewrite."}}]}"#)
        activeProtocol?.finishSSE()

        for _ in 0..<100 where session.phase.isRunning {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(session.phase, .finished)
        XCTAssertFalse(session.isThinking)
        XCTAssertEqual(session.output, "Polished rewrite.")

        coordinator.tearDown(stopSession: true)
        withExtendedLifetime(parentWindow) {}
    }

    func testClosingParentTabStopsRunningAISession() async throws {
        let thinkingStarted = expectation(description: "AI stream started")
        MockStreamProtocol.handler = { _, proto in
            proto.sendHeader()
            proto.sendSSE(#"{"choices":[{"delta":{"reasoning_content":"Thinking..."}}]}"#)
            thinkingStarted.fulfill()
        }

        let doc = DiffDocument(left: "Left", right: "Right")
        let store = AIStore(persists: false)
        var provider = AIProvider(kind: .oMLX)
        provider.model = "test-model"
        store.providers = [provider]

        let session = RewriteSession(urlSession: makeMockSession(), defaults: makeEphemeralDefaults())
        session.secondPass = .off
        session.providerID = provider.id

        let parentWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let coordinator = AIWindowPresenter.Coordinator(
            isPresented: Binding(get: { doc.isShowingAI }, set: { doc.isShowingAI = $0 }),
            document: doc,
            session: session
        )
        coordinator.attach(to: parentWindow)

        doc.showAI(.rewrite)
        coordinator.sync(
            isPresented: doc.isShowingAI,
            isRenamingTab: false,
            requestID: doc.aiRequestID,
            title: "AI — Diffactly",
            appearance: NSAppearance(named: .aqua)!
        )

        session.run(document: doc, store: store)
        await fulfillment(of: [thinkingStarted], timeout: 2.0)
        XCTAssertTrue(session.phase.isRunning)

        coordinator.tearDown(stopSession: true)
        XCTAssertFalse(session.phase.isRunning)
        XCTAssertFalse(doc.isShowingAI)
        withExtendedLifetime(parentWindow) {}
    }

    func testAuxiliaryWindowMapsBackToParentTabWindow() {
        let parent = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let aux = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        WindowTabs.registerAuxiliary(aux, for: parent)
        defer { WindowTabs.unregisterAuxiliary(aux) }

        XCTAssertTrue(WindowTabs.resolvedParent(for: aux) === parent)
        XCTAssertTrue(WindowTabs.resolvedParent(for: parent) === parent)
    }

    func testHasOpenThinkingTagDetectsAllSupportedTags() {
        XCTAssertTrue(RewriteSession.hasOpenThinkingTag("<think>reasoning"))
        XCTAssertFalse(RewriteSession.hasOpenThinkingTag("<think>reasoning</think>answer"))
        XCTAssertTrue(RewriteSession.hasOpenThinkingTag("<thinking>step 1"))
        XCTAssertFalse(RewriteSession.hasOpenThinkingTag("<thinking>step 1</thinking>"))
        XCTAssertTrue(RewriteSession.hasOpenThinkingTag("<reasoning>hmm"))
        XCTAssertFalse(RewriteSession.hasOpenThinkingTag("<reasoning>hmm</reasoning>done"))
    }

    func testEstimatedInputTokensUpdatesWhenDocumentChanges() {
        let doc = DiffDocument(left: "Short left.", right: "Short right.")
        let store = AIStore(persists: false)
        let session = RewriteSession(defaults: makeEphemeralDefaults())
        let initial = session.estimatedInputTokens(document: doc, store: store)
        XCTAssertEqual(initial, session.estimatedInputTokens(document: doc, store: store))

        doc.leftText = String(repeating: "word ", count: 500)
        let larger = session.estimatedInputTokens(document: doc, store: store)
        XCTAssertGreaterThan(larger, initial)
    }
}
