import XCTest

nonisolated final class ShareWorkspaceUITests: XCTestCase {
    private static let timeout: TimeInterval = 15
    private static let workspaceRow = "workspace.row.demo-ws-dashboard"

    @MainActor
    func testShareSheetCreatesInviteLinks() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = openShareSheet(appearance: appearance)
            let create = app.buttons["share-create-link"]
            XCTAssertTrue(create.appears(timeout: Self.timeout))
            capture(app, name: "Share workspace \(appearance)")
            create.tap()
            XCTAssertTrue(app.buttons["share-invite-send"].appears(timeout: Self.timeout), "Send the new link")
            app.buttons["share-invite-copy"].tap()
            XCTAssertTrue(app.buttons["Copied"].appears(timeout: Self.timeout), "Copy confirms")
            XCTAssertTrue(app.staticTexts["share-invite-summary"].label.hasSuffix("Expires in 7 days."), app.staticTexts["share-invite-summary"].label)
            capture(app, name: "Share workspace link created \(appearance)")
            app.terminate()

            let again = openShareSheet(appearance: appearance)
            again.buttons["One person"].tap()
            let login = again.textFields["share-pin-login"]
            XCTAssertTrue(login.appears(timeout: Self.timeout))
            login.tap()
            login.typeText("grace")
            capture(again, name: "Share workspace one person \(appearance)")
            again.buttons["share-create-link"].tap()
            XCTAssertTrue(again.buttons["share-invite-send"].appears(timeout: Self.timeout), "One-person link created")
            XCTAssertTrue(again.staticTexts["share-invite-summary"].label.hasPrefix("Only @grace can use this link, once."))
            again.terminate()
        }
    }

    @MainActor
    private func openShareSheet(appearance: String) -> XCUIApplication {
        let app = XCUIApplication.intent()
        app.launchArguments = ["--demo-data", "-appThemePreference", appearance]
        app.launch()
        let workspace = app.buttons[Self.workspaceRow]
        XCTAssertTrue(workspace.appears(timeout: Self.timeout))
        workspace.tap()
        let actions = app.buttons["Workspace actions"].firstMatch
        XCTAssertTrue(actions.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        actions.tap()
        let share = app.buttons["workspace.share"]
        XCTAssertTrue(share.appears(timeout: Self.timeout))
        share.tap()
        XCTAssertTrue(app.descendants(matching: .any)["share-workspace"].appears(timeout: Self.timeout), app.debugDescription)
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
