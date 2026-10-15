import XCTest

/// Opt-in failure evidence contract; the outer verifier requires the assertion to stay failed.
nonisolated final class FixtureCaptureLifecycleUITests: XCTestCase {
    @MainActor
    func testAssertionAbortRetainsFinalCapture() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["INTENT_CAPTURE_LIFECYCLE_CONTRACT"] == "1",
            "Run scripts/verify_fixture_capture_lifecycle.py for the intentional failure"
        )
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data"]
        app.launch()
        addTeardownBlock { @MainActor [self] () async in
            capture(app, name: "fixture-assertion-abort-final-state")
            app.terminate()
        }
        XCTAssertTrue(false, "fixture-capture-contract-intentional-assertion-abort")
        XCTFail("fixture-capture-contract-continued-after-abort")
    }

    @MainActor
    func testPassingFixtureRetainsRepeatedFinalCapture() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data"]
        app.launch()
        addTeardownBlock { @MainActor [self] () async in
            capture(app, name: "fixture-passing-final-state")
            capture(app, name: "fixture-passing-final-state")
            app.terminate()
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
