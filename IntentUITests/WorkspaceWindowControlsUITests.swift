import XCTest

/// Run on an iPad simulator with native Windowed Apps enabled, not a size-class override.
nonisolated final class WorkspaceWindowControlsUITests: XCTestCase {
    @MainActor
    func testCompactBackButtonsClearNativeWindowControls() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Requires native iPad window controls")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "-appThemePreference", "light"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let grabber = springboard.otherElements["resize-grabber"]
        try XCTSkipUnless(grabber.waitForExistence(timeout: 5), "Enable Windowed Apps on this simulator first")
        if app.windows.firstMatch.frame.width > 600 {
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.9))
            let start = grabber.isHittable
                ? grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                : app.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.995))
            start.press(forDuration: 0.3, thenDragTo: end)
        }
        XCTAssertLessThan(app.windows.firstMatch.frame.width, 600, "Must exercise a real compact window")
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 30))
        workspace.tap()
        let agent = app.buttons["workspace.agent.demo-agent-implementor"]
        XCTAssertTrue(agent.waitForExistence(timeout: 15))
        try capture(app, springboard: springboard, name: "workspace-detail")
        let windowControls = springboard.buttons["window-controls:dev.intentapp.ios"]
        assertClear(app.buttons["workspaceDetail.back"], of: windowControls)
        agent.tap()
        XCTAssertTrue(app.textViews["composer.textView"].waitForExistence(timeout: 15))
        try capture(app, springboard: springboard, name: "conversation")
        assertClear(app.buttons["conversation.back"], of: windowControls)
        app.buttons["conversation.back"].tap()
        XCTAssertTrue(agent.waitForExistence(timeout: 15))
        app.buttons["workspaceDetail.back"].tap()
        XCTAssertTrue(app.buttons["workspaces.search.open"].waitForExistence(timeout: 15))
    }

    @MainActor
    private func assertClear(_ back: XCUIElement, of windowControls: XCUIElement) {
        XCTAssertTrue(windowControls.waitForExistence(timeout: 5))
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertFalse(back.frame.intersects(windowControls.frame), "Back must not overlap the native window controls")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, springboard: XCUIApplication, name: String) throws {
        if let path = ProcessInfo.processInfo.environment["INTENT_WINDOW_CAPTURE_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
            try (app.debugDescription + "\nSPRINGBOARD\n" + springboard.debugDescription)
                .write(to: directory.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
        }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription + "\nSPRINGBOARD\n" + springboard.debugDescription)
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
