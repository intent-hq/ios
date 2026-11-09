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

        let scriptStatus = app.staticTexts["Run finished; agent notified"].firstMatch
        XCTAssertTrue(scriptStatus.waitForExistence(timeout: Self.timeout), "Script wakes render a wake card header")
        XCTAssertTrue(app.staticTexts["make check"].exists)
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

        let expandScript = app.buttons["Expand section"].firstMatch
        XCTAssertTrue(expandScript.exists)
        expandScript.tap()
        XCTAssertTrue(scriptBody.waitForExistence(timeout: Self.timeout), "Expanding shows the wake body")
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
