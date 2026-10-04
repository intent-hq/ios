import XCTest

nonisolated final class ConversationTranscriptHistoryUITests: XCTestCase {
    private let pageGate = FileManager.default.temporaryDirectory.appendingPathComponent("history-page-\(UUID().uuidString)")
    private let retryGate = FileManager.default.temporaryDirectory.appendingPathComponent("history-retry-\(UUID().uuidString)")
    private let hooksGate = FileManager.default.temporaryDirectory.appendingPathComponent("history-hooks-\(UUID().uuidString)")
    private static let maximumSwipes = 30

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        for file in [pageGate, retryGate, hooksGate] { try? FileManager.default.removeItem(at: file) }
        try super.tearDownWithError()
    }

    @MainActor
    func testOlderPagesPreserveReadingPositionAndRemainCachedOnReentry() throws {
        let app = launchHistory()
        let opened = openLongConversation(in: app)
        assertRestsAtBottom(lastRow: opened.lastMessage, named: "last message", endRow: .lastSuggestedPrompt(in: app), in: opened, context: "paged entry", allowPreservedEntry: true)
        XCTAssertTrue(followReport(in: opened).contains("historyCount=10 historyLoading=false"), "Entry must not fetch older pages")
        let beginning = app.staticTexts["transcript.historyBeginning"]
        XCTAssertFalse(beginning.exists)

        scrollUp(in: opened) { followReport(in: opened).contains("historyLoading=true") }
        XCTAssertFalse(beginning.exists, "The beginning label must not replace a pending page")
        let anchor = try XCTUnwrap(rows(intersecting: opened.transcript).first { row in
            row.label.hasPrefix("History message") && isInside(row.frame, opened.transcript)
        })
        let label = anchor.label
        let visible = message(in: app, containing: label)
        let before = try XCTUnwrap(waitUntilSteady(timeout: Fixture.settleTimeout, tolerance: Fixture.rePinTolerance) {
            frame(of: visible)?.minY ?? .nan
        })
        try Data().write(to: pageGate)
        XCTAssertTrue(waitUntil(timeout: Fixture.settleTimeout) { followReport(in: opened).contains("historyCount=20 historyLoading=false") })
        let measuredAfter = waitUntilSteady(timeout: Fixture.settleTimeout, tolerance: Fixture.rePinTolerance) {
            frame(of: visible)?.minY ?? .nan
        }
        let probe = app.descendants(matching: .any).matching(identifier: "transcript.gestureState").firstMatch
        let diagnostic = "anchor=\(label) before=\(before) \(followReport(in: opened)) live=\(String(describing: probe.exists ? probe.value : nil))"
        let attachment = XCTAttachment(string: diagnostic)
        attachment.lifetime = .keepAlways
        add(attachment)
        let after = try XCTUnwrap(measuredAfter, diagnostic)
        XCTAssertEqual(after, before, accuracy: Fixture.rePinTolerance, "Prepending history moved the reading position")
        XCTAssertTrue(opened.goToEnd.exists, "A history prepend must not clear Go to End")

        let first = message(in: app, containing: "History message 1.")
        scrollUp(in: opened) { isVisible(first, in: opened.transcript) && isVisible(beginning, in: opened.transcript) }
        XCTAssertEqual(beginning.label, "Beginning of conversation")
        XCTAssertTrue(followReport(in: opened).contains("olderAvailable=false"))
        XCTAssertFalse(app.buttons["transcript.historyRetry"].exists)
        XCTAssertFalse(app.progressIndicators["transcript.historyLoading"].exists)
        assertRetainedHistoryAndFreshEntry(in: app, opened: opened)
    }

    @MainActor
    func testFailedHistoryLoadCanBeRetriedWithoutLeavingConversation() throws {
        try Data().write(to: pageGate)
        let app = launchHistory(requiresRetry: true)
        let opened = openLongConversation(in: app)
        waitUntilSettled(on: opened.lastMessage, named: "last message", in: opened, context: "retry entry", allowPreservedEntry: true)
        let retry = app.buttons["transcript.historyRetry"]
        scrollUp(in: opened) { retry.exists && retry.isHittable }
        XCTAssertEqual(retry.label, "Couldn't load earlier messages — Retry")
        XCTAssertTrue(followReport(in: opened).contains("historyCount=10"))
        XCTAssertFalse(app.staticTexts["transcript.historyBeginning"].exists)
        try Data().write(to: retryGate)
        retry.tap()
        XCTAssertTrue(waitUntil(timeout: Fixture.settleTimeout) { followReport(in: opened).contains("historyCount=20") })
        let older = message(in: app, containing: "History message 11.")
        scrollUp(in: opened) { isVisible(older, in: opened.transcript) }
        XCTAssertFalse(retry.exists)
    }

    @MainActor
    private func assertRetainedHistoryAndFreshEntry(in app: XCUIApplication, opened: OpenConversation) {
        // This existing cover uses real navigation while keeping the view model
        // alive. The generic leave helper may restart the process instead.
        opened.goToEnd.tap()
        assertRestsAtBottom(lastRow: opened.lastMessage, named: "last message", endRow: .lastSuggestedPrompt(in: app), in: opened, context: "loaded history Go to End")
        let cover = app.buttons["demo.conversation.cover"]
        let consumer = (cover.value as? String)?.components(separatedBy: "consumer=").last
        XCTAssertNotNil(consumer)
        cover.tap()
        let back = app.buttons["demo.conversation.return"]
        XCTAssertTrue(back.waitForExistence(timeout: Fixture.settleTimeout))
        back.tap()
        XCTAssertTrue(opened.transcript.waitForExistence(timeout: Fixture.settleTimeout))
        XCTAssertEqual((cover.value as? String)?.components(separatedBy: "consumer=").last, consumer)
        assertRestsAtBottom(lastRow: opened.lastMessage, named: "last message", endRow: .lastSuggestedPrompt(in: app), in: opened, context: "retained history return", allowPreservedEntry: true)
        XCTAssertTrue(followReport(in: opened).contains("historyCount=30"), "A retained store must keep loaded history")

        // A fresh entry may recreate the weakly pooled store; regardless of
        // retention it must land at the bottom, without restarting the app.
        let conversationBack = app.buttons["conversation.back"]
        if conversationBack.exists { conversationBack.tap() } else { app.navigationBars.buttons.element(boundBy: 0).tap() }
        XCTAssertTrue(app.buttons[Fixture.overviewOnlyButton].waitForExistence(timeout: Fixture.settleTimeout))
        app.staticTexts[Fixture.agentName].firstMatch.tap()
        XCTAssertTrue(opened.transcript.waitForExistence(timeout: Fixture.settleTimeout))
        assertRestsAtBottom(lastRow: opened.lastMessage, named: "last message", endRow: .lastSuggestedPrompt(in: app), in: opened, context: "fresh history entry", allowPreservedEntry: true)
    }

    @MainActor
    private func launchHistory(requiresRetry: Bool = false) -> XCUIApplication {
        var arguments = ["--demo-history-pages", "--demo-history-page-trigger-file=" + pageGate.path]
        if requiresRetry { arguments.append("--demo-history-retry-trigger-file=" + retryGate.path) }
        return launchDemoApp(hooksRowTriggerFile: hooksGate, extraArguments: arguments)
    }

    @MainActor
    private func scrollUp(in opened: OpenConversation, until condition: () -> Bool) {
        for _ in 0..<Self.maximumSwipes {
            if condition() { return }
            opened.transcript.swipeDown()
        }
        XCTAssertTrue(condition(), "Older history never appeared: \(followReport(in: opened))")
    }
}
