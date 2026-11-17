import XCTest

/// The workspace Share sheet against demo fixtures (DemoSharingFixtures):
/// create a link anyone can use, then (reopened) one only a single GitHub
/// account can use. Nobody is added without a link.
nonisolated final class ShareWorkspaceUITests: XCTestCase {
    private static let timeout: TimeInterval = 15
    private static let workspaceRow = "workspace.row.demo-ws-dashboard"

    @MainActor
    func testShareSheetCreatesInviteLinks() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = openShareSheet(appearance: appearance)
            let create = app.buttons["share-create-link"]
            XCTAssertTrue(create.waitForExistence(timeout: Self.timeout))
            capture(app, name: "Share workspace \(appearance)")
            create.tap()
            XCTAssertTrue(app.buttons["share-invite-send"].waitForExistence(timeout: Self.timeout), "Send the new link")
            app.buttons["share-invite-copy"].tap()
            XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: Self.timeout))
            capture(app, name: "Share workspace link created \(appearance)")
            app.terminate()

            let again = openShareSheet(appearance: appearance)
            again.buttons["One person"].tap()
            let login = again.textFields["share-pin-login"]
            XCTAssertTrue(login.waitForExistence(timeout: Self.timeout))
            login.tap()
            login.typeText("grace")
            capture(again, name: "Share workspace one person \(appearance)")
            again.buttons["share-create-link"].tap()
            XCTAssertTrue(again.buttons["share-invite-send"].waitForExistence(timeout: Self.timeout), "One-person link created")
            again.terminate()
        }
    }

    @MainActor
    private func openShareSheet(appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "-appThemePreference", appearance]
        app.launch()
        let workspace = app.buttons[Self.workspaceRow]
        XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
        workspace.tap()
        let actions = app.buttons["Workspace actions"].firstMatch
        XCTAssertTrue(actions.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        actions.tap()
        let share = app.buttons["workspace.share"]
        XCTAssertTrue(share.waitForExistence(timeout: Self.timeout))
        share.tap()
        XCTAssertTrue(app.descendants(matching: .any)["share-workspace"].waitForExistence(timeout: Self.timeout), app.debugDescription)
        return app
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
