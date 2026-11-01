import XCTest

extension IPadSidebarUITests {
    @MainActor
    func testPullRequestsSectionListsAndOpensDetailInBothThemes() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad sidebar navigation")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        for appearance in ["light", "dark"] {
            let app = launchDemo(appearance: appearance)
            app.buttons["ipad.rail.pullRequests"].tap()
            XCTAssertTrue(app.buttons["ipad.rail.pullRequests"].isSelected)
            let row = app.buttons["pullRequests.row.nova-labs/console#482"]
            XCTAssertTrue(row.waitForExistence(timeout: Self.pullRequestsTimeout))
            attachScreenshot(named: "iPad pull requests \(appearance)")
            row.tap()
            let checks = app.buttons["pullRequest.checks"]
            XCTAssertTrue(checks.waitForExistence(timeout: Self.pullRequestsTimeout))
            attachScreenshot(named: "iPad pull request detail \(appearance)")
            app.buttons["pullRequest.back"].tap()
            XCTAssertTrue(checks.waitForNonExistence(timeout: Self.pullRequestsTimeout))
            app.buttons["ipad.rail.workspaces"].tap()
            XCTAssertTrue(app.buttons["ipad.rail.workspaces"].isSelected)
            app.terminate()
        }
    }

    private static let pullRequestsTimeout: TimeInterval = 30

    @MainActor
    private func launchDemo(appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "-appThemePreference", appearance]
        app.launch()
        XCTAssertTrue(app.buttons["ipad.rail.workspaces"].waitForExistence(timeout: Self.pullRequestsTimeout))
        return app
    }

    @MainActor
    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
