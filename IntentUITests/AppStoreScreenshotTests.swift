import XCTest

/// Captures the App Store screenshot set via `fastlane snapshot`.
///
/// Run on a Mac from the repo root with `bundle exec fastlane screenshots`
/// (or `fastlane snapshot`); see fastlane/Snapfile for device configuration.
///
/// The app is launched with `--demo-data` (see DemoFixtures.swift), which
/// skips pairing and serves polished fixture data with no daemon, so every
/// screen shows realistic marketing-safe content.
final class AppStoreScreenshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 01–04: workspace list → workspace detail → agent conversation →
    /// note with tasks, all against `--demo-data` fixture content.
    @MainActor
    func testCaptureDemoModeScreenshots() throws {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments += ["--demo-data"]
        app.launch()

        // 01 — workspace list ("Add usage analytics dashboard" is the first
        // fixture workspace; on iPad it renders in the sidebar).
        let workspaceRow = app.staticTexts["Add usage analytics dashboard"].firstMatch
        XCTAssertTrue(workspaceRow.waitForExistence(timeout: 30))
        snapshot("01-workspace-list")

        // 02 — workspace detail (agents tab with fixture agents).
        workspaceRow.tap()
        let agentRow = app.staticTexts["Dashboard Implementor"].firstMatch
        XCTAssertTrue(agentRow.waitForExistence(timeout: 15))
        snapshot("02-workspace-detail")

        // 03 — agent conversation (fixture transcript).
        agentRow.tap()
        let conversationMessage = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS[c] %@", "more than 90 days"))
            .firstMatch
        XCTAssertTrue(conversationMessage.waitForExistence(timeout: 15))
        snapshot("03-agent-conversation")

        // Back to workspace detail (first nav-bar button is the back button
        // on iPhone and the custom "Agents" button on iPad).
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(agentRow.waitForExistence(timeout: 15))

        // 04 — note with tasks (Context tab → "Spec" fixture note, which
        // contains a checkbox task list).
        app.buttons["Context"].firstMatch.tap()
        let specRow = app.staticTexts["Spec"].firstMatch
        XCTAssertTrue(specRow.waitForExistence(timeout: 15))
        specRow.tap()
        XCTAssertTrue(app.navigationBars["Spec"].waitForExistence(timeout: 15))
        snapshot("04-note-tasks")
    }

    /// 05: pairing screen — launched WITHOUT demo arguments so the app lands
    /// on the pairing options (no saved connection exists on the fresh
    /// simulators fastlane snapshot boots). Marketing-safe: no camera or QR
    /// scanner is opened, only the option list is shown.
    @MainActor
    func testCapturePairingScreenshot() throws {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launch()

        let scanOption = app.staticTexts["Scan QR Code"].firstMatch
        XCTAssertTrue(scanOption.waitForExistence(timeout: 30))
        snapshot("05-pairing")
    }
}
