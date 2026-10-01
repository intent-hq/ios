import XCTest

nonisolated final class ConversationMarkdownTableUITests: XCTestCase {
    private static let timeout: TimeInterval = 15

    @MainActor
    func testTableScrollsHorizontallyWithoutCapturingVerticalTranscriptSwipes() {
        verifyTable(accessibleText: false)
    }

    @MainActor
    func testTableRemainsReachableWithAccessibilityTextInPortrait() {
        verifyTable(accessibleText: true)
    }

    @MainActor
    private func verifyTable(accessibleText: Bool) {
        continueAfterFailure = false
        // iPhone supports portrait only, including the AX5 flow through Go to End.
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-design-scenario=tables"]
        if accessibleText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        defer { app.terminate() }
        let workspace = app.staticTexts["Workspace agent design"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
        workspace.tap()
        let agent = app.staticTexts["Continue Spec Writer"].firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: Self.timeout))
        agent.tap()
        let transcript = app.scrollViews["transcript.scrollView"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: Self.timeout))
        let setup = transcript.staticTexts["Setup"].firstMatch
        revealHeader(setup, in: transcript)
        capture(app, name: accessibleText ? "table-accessibility-portrait" : "table-portrait")
        XCTAssertTrue(isInside(setup, transcript))
        let table = transcript.scrollViews.containing(.staticText, identifier: "Setup").firstMatch
        XCTAssertTrue(table.exists, "The table needs its own horizontal scrolling region")
        let peak = transcript.staticTexts["Peak memory"].firstMatch
        for _ in 0..<20 where !isInside(peak, transcript) {
            table.swipeLeft()
        }
        XCTAssertTrue(isInside(peak, transcript), "The entire final column header must be reachable")
        capture(app, name: "table-last-column")
        for _ in 0..<20 where !isInside(setup, transcript) {
            table.swipeRight()
        }
        XCTAssertTrue(isInside(setup, transcript), "The first column must remain reachable")
        let before = setup.frame.minY
        swipeUpOverVisibleTable(table, in: transcript)
        XCTAssertLessThan(setup.frame.minY, before - 20, "A vertical swipe over the table must move the transcript")
        verifyGoToEnd(in: app, transcript: transcript)
    }

    @MainActor
    private func verifyGoToEnd(in app: XCUIApplication, transcript: XCUIElement) {
        let goToEnd = app.buttons["transcript.goToEnd"].firstMatch
        if !goToEnd.exists { transcript.swipeDown() }
        XCTAssertTrue(goToEnd.waitForExistence(timeout: Self.timeout))
        goToEnd.tap()
        let end = transcript.staticTexts["End of the table comparison."].firstMatch
        XCTAssertTrue(waitUntil(timeout: Self.timeout) { isVisible(end, in: transcript) })
    }

    @MainActor
    private func swipeUpOverVisibleTable(_ table: XCUIElement, in transcript: XCUIElement) {
        let visible = table.frame.intersection(transcript.frame.insetBy(dx: 0, dy: 80))
        XCTAssertGreaterThan(visible.height, 60)
        let origin = transcript.coordinate(withNormalizedOffset: .zero)
        let xOffset = visible.midX - transcript.frame.minX
        let start = origin.withOffset(CGVector(dx: xOffset, dy: visible.maxY - transcript.frame.minY - 10))
        let end = origin.withOffset(CGVector(dx: xOffset, dy: visible.minY - transcript.frame.minY + 10))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func revealHeader(_ header: XCUIElement, in transcript: XCUIElement) {
        // A full-screen fling can skip the header, especially at large text sizes.
        // Correct in either direction instead of continuing past the table to the top.
        for _ in 0..<40 {
            let viewport = transcript.frame.insetBy(dx: 0, dy: 80)
            let headerFrame = frame(of: header)
            if let headerFrame, viewport.contains(headerFrame) { return }
            let belowViewport = (headerFrame?.midY ?? -.infinity) > viewport.midY
            let start = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: belowViewport ? 0.25 : 0.75))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTFail("The table header could not be positioned inside the visible transcript")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
