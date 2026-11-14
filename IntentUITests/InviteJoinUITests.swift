import XCTest

/// The `intent://invite` join sheet against the demo invite seam
/// (`--demo-invite`, DemoInviteJoin): confirm-then-join, the explanation
/// when this device has no Mac to confirm the account, and a host refusal.
nonisolated final class InviteJoinUITests: XCTestCase {
    private static let timeout: TimeInterval = 15

    @MainActor
    func testFirstJoinAsksBeforeProvingThenJoins() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(scenario: "first-join", appearance: appearance)
            let title = app.staticTexts["invite-join-title"]
            XCTAssertTrue(title.waitForExistence(timeout: Self.timeout), app.debugDescription)
            XCTAssertEqual(title.label, "Billing revamp")
            let explanation = app.staticTexts["invite-join-explanation"]
            XCTAssertTrue(explanation.label.contains("Ada's MacBook Pro"), explanation.label)
            XCTAssertTrue(explanation.label.contains("GitHub"), explanation.label)
            let join = app.buttons["invite-join-button"]
            XCTAssertTrue(join.exists)
            XCTAssertTrue(join.label.contains("@ada"), join.label)
            capture(app, name: "Invite join confirm \(appearance)")

            join.tap()
            XCTAssertTrue(title.waitForNonExistence(timeout: Self.timeout), "Joining closes the sheet")
            app.terminate()
        }
    }

    @MainActor
    func testInviteWithoutAnOwnMacExplainsAndOffersCopyLink() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(scenario: "no-mac", appearance: appearance)
            let title = app.staticTexts["invite-join-message-title"]
            XCTAssertTrue(title.waitForExistence(timeout: Self.timeout), app.debugDescription)
            XCTAssertEqual(title.label, "Confirm Your Account on Your Mac")
            XCTAssertTrue(app.buttons["invite-join-copy-link"].exists)
            XCTAssertFalse(app.buttons["invite-join-button"].exists, "Nothing to join from here")
            capture(app, name: "Invite join needs Mac \(appearance)")
            app.terminate()
        }
    }

    @MainActor
    func testExpiredInviteExplainsWithoutRetry() {
        continueAfterFailure = false
        let app = launch(scenario: "expired", appearance: "light")
        let title = app.staticTexts["invite-join-message-title"]
        XCTAssertTrue(title.waitForExistence(timeout: Self.timeout), app.debugDescription)
        XCTAssertEqual(title.label, "Invite Expired")
        XCTAssertFalse(app.buttons["invite-join-retry"].exists, "An expired link can't succeed on retry")
        capture(app, name: "Invite join expired light")
    }

    @MainActor
    private func launch(scenario: String, appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "--demo-invite=\(scenario)", "-appThemePreference", appearance]
        app.launch()
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
