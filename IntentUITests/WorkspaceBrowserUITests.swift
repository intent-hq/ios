import XCTest

nonisolated final class WorkspaceBrowserUITests: XCTestCase {
    private static let timeout: TimeInterval = 15

    @MainActor
    func testAgentBrowserAppearsAndMessageLinkOpensInApp() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "--demo-browsers"]
        app.launch()
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
        workspace.tap()
        let browser = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Agent browser")).firstMatch
        for _ in 0..<3 where !browser.isHittable { app.swipeUp() }
        XCTAssertTrue(browser.waitForExistence(timeout: Self.timeout))
        browser.tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: Self.timeout))
        done.tap()
        let agent = app.buttons["workspace.agent.demo-agent-implementor"]
        for _ in 0..<3 where !agent.isHittable { app.swipeDown() }
        XCTAssertTrue(agent.waitForExistence(timeout: Self.timeout))
        agent.tap()
        let link = app.links["Open server preview"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: Self.timeout))
        link.tap()
        XCTAssertTrue(done.waitForExistence(timeout: Self.timeout))
        let address = app.textFields["Browser URL"]
        XCTAssertEqual(address.value as? String, "http://127.0.0.1:5173/preview?view=phone")
        address.tap()
        let delete = String(repeating: XCUIKeyboardKey.delete.rawValue, count: (address.value as? String ?? "").count)
        address.typeText(delete + "127.0.0.1:4321/settings\n")
        XCTAssertEqual(address.value as? String, "http://127.0.0.1:4321/settings")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "workspace-browser-address-bar"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        done.tap()
        XCTAssertTrue(link.waitForExistence(timeout: Self.timeout))
    }

    @MainActor
    func testCreatingBrowserValidatesAddressAndKeepsSessionAfterDismissal() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "--demo-browsers"]
        app.launch()
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
        workspace.tap()
        let actions = app.buttons["Workspace actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: Self.timeout))
        actions.tap()
        app.buttons["New browser"].tap()
        let address = app.textFields["Browser address"]
        XCTAssertTrue(address.waitForExistence(timeout: Self.timeout))
        address.tap()
        address.typeText("file:///etc/passwd")
        app.navigationBars.buttons["Open"].tap()
        XCTAssertTrue(address.exists)
        address.tap()
        let delete = String(repeating: XCUIKeyboardKey.delete.rawValue, count: "file:///etc/passwd".count)
        address.typeText(delete + "localhost:3000")
        app.navigationBars.buttons["Open"].tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: Self.timeout))
        done.tap()
        XCTAssertTrue(actions.waitForExistence(timeout: Self.timeout))
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", ":3000")).firstMatch
        if !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: Self.timeout))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "workspace-browsers"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        row.tap()
        XCTAssertTrue(done.waitForExistence(timeout: Self.timeout))
        done.tap()
        for _ in 0..<3 where !row.isHittable { app.swipeUp() }
        row.swipeLeft()
        let deleteButton = app.buttons["Delete browser"].firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: Self.timeout))
        deleteButton.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: Self.timeout))
    }

    @MainActor
    func testSwipingAnAgentBrowserRevealsDeleteWithoutOpeningThePage() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "--demo-browsers"]
        app.launch()
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
        workspace.tap()
        let browser = app.buttons["browser.row.tab:demo-agent-browser"]
        for _ in 0..<3 where !browser.isHittable { app.swipeUp() }
        XCTAssertTrue(browser.waitForExistence(timeout: Self.timeout))
        browser.swipeLeft()
        let deleteButton = app.buttons["browser.delete.tab:demo-agent-browser"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(deleteButton.isHittable)
        XCTAssertFalse(app.textFields["Browser URL"].exists)
        browser.swipeRight()
        XCTAssertFalse(deleteButton.isHittable)
        XCTAssertTrue(browser.exists)
        browser.swipeLeft()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "workspace-browser-swipe-delete"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        deleteButton.tap()
        XCTAssertTrue(browser.waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["browser.row.script:preview"].exists)
    }
}
