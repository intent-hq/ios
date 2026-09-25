import XCTest

nonisolated final class AssistantProposalUITests: XCTestCase {
    private static let timeout: TimeInterval = 30

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        continueAfterFailure = true
        try super.tearDownWithError()
    }

    @MainActor
    func testArchiveSelectionAndSavedOutcome() {
        let app = openAssistant(arguments: ["--demo-assistant-proposal"])
        let apply = app.buttons["proposal.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: Self.timeout))
        let item = app.buttons["proposal.item.demo-ws-flaky-tests"]
        XCTAssertTrue(item.isSelected)
        XCTAssertEqual(item.value as? String, "On")
        captureSwitches(in: app, name: "Assistant switches on")
        item.tap()
        XCTAssertFalse(item.isSelected)
        XCTAssertEqual(item.value as? String, "Off")
        captureSwitches(in: app, name: "Assistant switches off")
        XCTAssertFalse(apply.isEnabled)
        item.tap()
        XCTAssertTrue(item.isSelected)
        XCTAssertTrue(apply.isEnabled)
        XCTAssertFalse(app.buttons["assistant.workspace.demo-ws-flaky-tests"].exists)
        apply.tap()
        let outcome = app.staticTexts["proposal.outcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(outcome.label, "Applied")
        XCTAssertFalse(apply.exists)
    }

    @MainActor
    func testDismissProposal() {
        let app = openAssistant(arguments: ["--demo-assistant-proposal"])
        let dismiss = app.buttons["proposal.dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: Self.timeout))
        dismiss.tap()
        app.buttons["Dismiss proposal"].tap()
        let outcome = app.staticTexts["proposal.outcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(outcome.label, "Dismissed")
    }

    @MainActor
    func testStreamingMarkerStaysHiddenUntilWorkspaceCardIsReady() throws {
        let trigger = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-stream-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: trigger) }
        let app = openAssistant(arguments: ["--demo-workspace-stream-trigger=\(trigger.path)"])
        XCTAssertTrue(app.staticTexts["Workspace links are loading."].waitForExistence(timeout: Self.timeout))
        let raw = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "@@@")).firstMatch
        XCTAssertFalse(raw.exists)
        try Data().write(to: trigger)
        XCTAssertTrue(app.buttons["assistant.workspace.demo-ws-flaky-tests"].waitForExistence(timeout: Self.timeout))
        XCTAssertFalse(raw.exists)
    }

    @MainActor
    private func captureSwitches(in app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func openAssistant(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data"] + arguments
        app.launch()
        let launcher = app.buttons["assistant.open"]
        XCTAssertTrue(launcher.waitForExistence(timeout: Self.timeout))
        launcher.tap()
        return app
    }
}
