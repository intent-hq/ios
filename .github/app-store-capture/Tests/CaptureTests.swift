import XCTest

nonisolated final class CaptureTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testListingScreens() throws {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        #endif
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        dismissNotificationPrompt()
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 30))
        try capture("01-workspace-list")
        workspace.tap()
        let agent = app.staticTexts["Dashboard Implementor"].firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: 20))
        try capture("02-workspace-detail")
        agent.tap()
        let message = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "more than 90 days")
        ).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 20))
        try capture("03-agent-conversation")
        let customBack = app.buttons["conversation.back"].firstMatch
        let nativeBack = app.navigationBars["Dashboard Implementor"].buttons.element(boundBy: 0)
        let back = customBack.exists ? customBack : nativeBack
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
        XCTAssertTrue(agent.waitForExistence(timeout: 15))
        #if os(visionOS)
        let notesTab = app.segmentedControls.firstMatch.buttons.element(boundBy: 1)
        XCTAssertTrue(notesTab.waitForExistence(timeout: 10), app.debugDescription)
        notesTab.tap()
        #else
        app.buttons["Context"].firstMatch.tap()
        #endif
        let spec = app.staticTexts["Spec"].firstMatch
        XCTAssertTrue(spec.waitForExistence(timeout: 15))
        spec.tap()
        let note = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Per-team daily/weekly active seat counts")
        ).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 20))
        try capture("04-note-tasks")
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        #if os(visionOS)
        let pairing = app.staticTexts["Manual Connection"].firstMatch
        #else
        let pairing = app.staticTexts["Scan QR Code"].firstMatch
        #endif
        XCTAssertTrue(pairing.waitForExistence(timeout: 20))
        try capture("05-pairing")
        app.terminate()
    }

    @MainActor
    private func dismissNotificationPrompt() {
        #if os(visionOS)
        let system = XCUIApplication(bundleIdentifier: "com.apple.SurfBoard")
        #else
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        #endif
        let allow = system.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 3) {
            allow.tap()
            XCTAssertTrue(allow.waitForNonExistence(timeout: 5))
        }
    }

    @MainActor
    private func capture(_ name: String) throws {
        let directory = try XCTUnwrap(ProcessInfo.processInfo.environment["CAPTURE_OUTPUT"])
        let root = URL(fileURLWithPath: directory)
        // The host takes simctl screenshots to include the actual visionOS scene.
        // Acknowledgement holds navigation until the frame has been saved.
        Thread.sleep(forTimeInterval: 2)
        dismissNotificationPrompt()
        try Data(name.utf8).write(to: root.appendingPathComponent("request"), options: .atomic)
        let acknowledgement = root.appendingPathComponent(name + ".done").path
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: acknowledgement), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: acknowledgement), "Host capture missing: \(name)")
    }
}
