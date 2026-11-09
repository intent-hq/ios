import XCTest

nonisolated final class AutomatedMessageUITests: XCTestCase {
    private static let timeout: TimeInterval = 15
    private static let agentMessageBody = "Review the attachment flow on iPad and report back with screenshots."

    @MainActor
    func testAgentMessageCollapsesAndScriptWakeRendersAsACard() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-design-scenario=automated-messages"]
        app.launch()
        addTeardownBlock { @MainActor [self] () async in
            attachScreenshot(app, name: "Automated messages final state")
        }
        let workspace = app.staticTexts["Workspace agent design"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
        workspace.tap()
        let agent = app.staticTexts["Continue Spec Writer"].firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: Self.timeout))
        agent.tap()

        let scriptHeader = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@", "make check", "Run finished; agent notified"
        )).firstMatch
        XCTAssertTrue(scriptHeader.waitForExistence(timeout: Self.timeout), "Script wakes render one wake card header")
        let scriptBody = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Monitoring ended")).firstMatch
        XCTAssertFalse(scriptBody.exists, "Script wake cards start collapsed")

        let disclosure = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "sent a message")).firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(disclosure.value as? String, "collapsed")
        let body = app.staticTexts[Self.agentMessageBody].firstMatch
        XCTAssertFalse(body.exists, "Agent messages start collapsed")
        attachScreenshot(app, name: "Automated messages collapsed")

        disclosure.tap()
        XCTAssertTrue(body.waitForExistence(timeout: Self.timeout), "Expanding shows the message body")
        let header = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "[MESSAGE FROM AGENT")).firstMatch
        XCTAssertFalse(header.exists, "The daemon sender header is display-stripped")
        attachScreenshot(app, name: "Automated messages agent expanded")

        XCTAssertEqual(scriptHeader.value as? String, "Collapsed")
        scriptHeader.tap()
        XCTAssertTrue(scriptBody.waitForExistence(timeout: Self.timeout), "Tapping the header row shows the wake body")
        XCTAssertEqual(scriptHeader.value as? String, "Expanded")
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
