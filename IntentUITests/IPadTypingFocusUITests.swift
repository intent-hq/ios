import XCTest

nonisolated final class IPadTypingFocusUITests: XCTestCase {
    private static let timeout: TimeInterval = 30

    @MainActor
    func testSendingRestoresConversationInBothThemes() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad typing focus")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["--demo-data", "-appThemePreference", appearance]
            app.launch()
            let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
            XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
            workspace.tap()
            let agent = app.buttons["workspace.agent.demo-agent-implementor"]
            XCTAssertTrue(agent.waitForExistence(timeout: Self.timeout))
            agent.tap()
            let composer = try app.textViews.matching(identifier: "composer.textView").singleHittableElement()
            composer.tap()
            composer.typeText("Check the iPad chat transition")
            let close = app.buttons["ipad.focus.close"]
            XCTAssertTrue(close.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
            try app.buttons.matching(identifier: "composer.send").singleHittableElement().tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: Self.timeout))
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: Self.timeout))
            XCTAssertEqual(composer.value as? String, "")
            XCTAssertTrue(app.buttons["ipad.rail.workspaces"].isSelected)
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "iPad prompt sent \(appearance)"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }
}
