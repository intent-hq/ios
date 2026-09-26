import XCTest

/// Exercises the real composer and monitor actions through the deterministic
/// design demo's transport, not a separate screenshot-only screen.
nonisolated final class WorkspaceComposerUITests: XCTestCase {
    private enum Fixture {
        static let timeout: TimeInterval = 15
        static let minimumTapTarget: CGFloat = 44
        static let workspace = "Workspace agent design"
        static let agent = "Continue Spec Writer"
        static let monitor = "monitoredPr.demo-design-pr-56"
    }

    @MainActor
    func testMultilineSendAndStopPreserveAnInProgressDraft() {
        let app = launch(scenario: "composer")
        let composer = app.textViews["composer.textView"]
        let send = app.buttons["composer.send"]
        let stop = app.buttons["composer.stop"]
        XCTAssertFalse(send.exists, "The empty composer has no send action")
        XCTAssertFalse(stop.exists)

        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Fixture.timeout))
        let message = "Make the logo bigger\nand keep its proportions"
        composer.typeText(message)
        XCTAssertEqual(composer.value as? String, message, "Return on iPhone inserts a newline instead of sending")
        XCTAssertTrue(send.waitForExistence(timeout: Fixture.timeout))
        assertReachable(send, in: app)
        send.tap()

        XCTAssertTrue(stop.waitForExistence(timeout: Fixture.timeout), "The actual send starts a streaming response")
        XCTAssertEqual(composer.value as? String, "")
        let sentMessage = app.scrollViews["transcript.scrollView"].staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Make the logo bigger", "keep its proportions"))
            .firstMatch
        XCTAssertTrue(sentMessage.waitForExistence(timeout: Fixture.timeout))

        let draft = "Keep this draft while stopping"
        composer.tap()
        composer.typeText(draft)
        XCTAssertTrue(send.waitForExistence(timeout: Fixture.timeout))
        assertReachable(send, in: app)
        assertReachable(stop, in: app)
        assertReachable(app.buttons["composer.attachment"], in: app)
        stop.tap()
        XCTAssertTrue(stop.waitForNonExistence(timeout: Fixture.timeout))
        XCTAssertEqual(composer.value as? String, draft, "Stop must not consume the next message")
        XCTAssertTrue(send.isEnabled)
    }

    @MainActor
    func testMonitoringAndAttachmentMenusKeepTheirActions() {
        let app = launch(scenario: "conversation")
        let monitor = app.buttons[Fixture.monitor]
        XCTAssertTrue(monitor.waitForExistence(timeout: Fixture.timeout))
        assertReachable(monitor, in: app)
        monitor.tap()
        XCTAssertTrue(app.buttons["Check and flush"].waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.buttons["Open PR"].exists)
        let cancel = app.buttons["Cancel monitor"]
        XCTAssertTrue(cancel.exists)
        cancel.tap()
        XCTAssertTrue(monitor.waitForNonExistence(timeout: Fixture.timeout), "Cancellation must remove the live monitor")

        let attachment = app.buttons["composer.attachment"]
        assertReachable(attachment, in: app)
        attachment.tap()
        XCTAssertTrue(app.buttons["Photos"].waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.buttons["Files"].exists)
    }

    @MainActor
    func testAccessibilityTextKeepsDraftAndStreamingActionsReachable() {
        let app = launch(scenario: "streaming", accessibleText: true)
        let composer = app.textViews["composer.textView"]
        composer.tap()
        let draft = "An accessible draft with enough text to wrap onto multiple lines"
        composer.typeText(draft)
        XCTAssertEqual(composer.value as? String, draft)
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: Fixture.timeout))
        assertReachable(send, in: app)
        assertReachable(app.buttons["composer.stop"], in: app)
        assertReachable(app.buttons["composer.attachment"], in: app)
    }

    @MainActor
    private func launch(scenario: String, accessibleText: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-design-scenario=\(scenario)"]
        if accessibleText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        let workspace = app.staticTexts[Fixture.workspace].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.timeout))
        workspace.tap()
        XCTAssertTrue(app.buttons["Context"].waitForExistence(timeout: Fixture.timeout))
        let agent = app.staticTexts[Fixture.agent].firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: Fixture.timeout))
        agent.tap()
        XCTAssertTrue(app.textViews["composer.textView"].waitForExistence(timeout: Fixture.timeout))
        return app
    }

    @MainActor
    private func assertReachable(_ control: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(control.isHittable)
        XCTAssertGreaterThanOrEqual(control.frame.width, Fixture.minimumTapTarget)
        XCTAssertGreaterThanOrEqual(control.frame.height, Fixture.minimumTapTarget)
        XCTAssertTrue(app.frame.contains(control.frame), "Control must not be clipped by the viewport")
    }
}
