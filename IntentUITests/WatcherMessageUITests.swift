import XCTest

nonisolated final class WatcherMessageUITests: XCTestCase {
    private static let timeout: TimeInterval = 15

    @MainActor
    func testWatcherDetailsExpandAndCollapseWithoutLosingTheReport() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-design-scenario=watcher"]
        app.launch()
        addTeardownBlock { @MainActor [self] () async in
            attachScreenshot(app, name: "Watcher final state")
        }
        let workspace = app.staticTexts["Workspace agent design"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
        workspace.tap()
        let agent = app.staticTexts["Continue Spec Writer"].firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: Self.timeout))
        agent.tap()
        let header = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Watch iOS Mermaid validation")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: Self.timeout), "The wake header row is one button")
        XCTAssertEqual(header.value as? String, "Collapsed", "Wake cards start collapsed")
        XCTAssertFalse(app.staticTexts["Build report"].exists, "A collapsed wake card hides its report")
        attachScreenshot(app, name: "Watcher collapsed")
        header.tap()
        let show = app.buttons["Show details"]
        XCTAssertTrue(show.waitForExistence(timeout: Self.timeout), "Tapping the header row expands the card")
        XCTAssertEqual(header.value as? String, "Expanded")
        XCTAssertTrue(app.staticTexts["Build report"].exists, "Watcher prose must decode context mentions")
        let rawDetails = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Lint sources")).firstMatch
        XCTAssertFalse(rawDetails.exists, "The report must start collapsed")
        attachScreenshot(app, name: "Watcher summary")

        show.tap()
        let hide = app.buttons["Hide details"]
        XCTAssertTrue(hide.waitForExistence(timeout: Self.timeout), "The tap must expand the watcher card")
        XCTAssertTrue(rawDetails.waitForExistence(timeout: Self.timeout), "Expansion must expose nested job details")
        attachScreenshot(app, name: "Watcher expanded details")
        hide.tap()
        XCTAssertTrue(rawDetails.waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(show.exists)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
