import XCTest

/// Captures the App Store screenshot set via `fastlane snapshot`.
///
/// Run on a Mac from the repo root with `bundle exec fastlane screenshots`
/// (see fastlane/Snapfile for device configuration). Always use that lane —
/// it erases the simulators and seeds SpringBoard prefs first (Fastfile →
/// prepare_screenshot_simulators); a direct `fastlane snapshot` run skips
/// that preparation.
///
/// The app is launched with `--demo-data` (see DemoFixtures.swift), which
/// skips pairing and serves polished fixture data with no daemon, so every
/// screen shows realistic marketing-safe content.
nonisolated final class AppStoreScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        continueAfterFailure = true
        try super.tearDownWithError()
    }

    @MainActor
    private func configureOrientation() {
        // App Store iPad screenshots are captured in landscape (the split
        // view shows sidebar + detail side by side); iPhone stays portrait.
        // Must be set before app.launch() so the app renders at the right
        // dimensions from the first frame.
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
    }

    @MainActor
    private func dismissNotificationPrompt() {
        let allowNotifications = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allowNotifications.waitForExistence(timeout: 2) {
            allowNotifications.tap()
            XCTAssertTrue(allowNotifications.waitForNonExistence(timeout: 5))
        }
    }

    /// 01–04: workspace list → workspace detail → agent conversation →
    /// note with tasks, all against `--demo-data` fixture content.
    @MainActor
    func testCaptureDemoModeScreenshots() {
        configureOrientation()
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments += ["--demo-data"]
        app.launch()
        dismissNotificationPrompt()

        // 01 — workspace list ("Add usage analytics dashboard" is the first
        // fixture workspace; on iPad landscape it renders in the always-
        // visible sidebar next to the empty-detail placeholder).
        let workspaceRow = app.staticTexts["Add usage analytics dashboard"].firstMatch
        if !workspaceRow.waitForExistence(timeout: 30) {
            // Fallback: if the split-view sidebar launched collapsed, the
            // first nav-bar button is the sidebar toggle — reveal the
            // workspace list before failing.
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(workspaceRow.waitForExistence(timeout: 15))
        }
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

        let customBackButton = app.buttons["conversation.back"]
        let nativeBackButton = app.navigationBars["Dashboard Implementor"].buttons.element(boundBy: 0)
        let agentsBackButton = customBackButton.exists ? customBackButton : nativeBackButton
        XCTAssertTrue(agentsBackButton.waitForExistence(timeout: 15))
        agentsBackButton.tap()
        XCTAssertTrue(agentRow.waitForExistence(timeout: 15))

        // 04 — note with tasks (Context tab → "Spec" fixture note, which
        // contains linked task cards).
        app.buttons["Context"].firstMatch.tap()
        let specRow = app.staticTexts["Spec"].firstMatch
        XCTAssertTrue(specRow.waitForExistence(timeout: 15))
        specRow.tap()
        XCTAssertTrue(app.navigationBars["Spec"].waitForExistence(timeout: 15))
        let loadedNote = app.buttons["Open task CSV export with streamed download"]
        XCTAssertTrue(loadedNote.waitForExistence(timeout: 15))
        snapshot("04-note-tasks")
    }

    /// 05: pairing screen — launched WITHOUT demo arguments so the app lands
    /// on the pairing options (no saved connection exists on the freshly
    /// erased simulators the `screenshots` lane prepares). Marketing-safe:
    /// no camera or QR scanner is opened, only the option list is shown.
    @MainActor
    func testCapturePairingScreenshot() {
        configureOrientation()
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launch()
        dismissNotificationPrompt()

        let scanOption = app.staticTexts["Scan QR Code"].firstMatch
        XCTAssertTrue(scanOption.waitForExistence(timeout: 30))
        snapshot("05-pairing")
    }
}
