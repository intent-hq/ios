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
    func testCreateWorkspaceFromProposalAndOpenIt() {
        let app = openAssistant(arguments: ["--demo-assistant-workspace-proposal"])
        let apply = app.buttons["proposal.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(apply.label, "Create")
        captureSwitches(in: app, name: "Workspace proposal review")
        apply.tap()
        let outcome = app.staticTexts["proposal.outcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(outcome.label, "Workspace created")
        let open = app.buttons["proposal.openWorkspace"]
        XCTAssertTrue(open.exists)
        captureSwitches(in: app, name: "Workspace proposal created")
        open.tap()
        XCTAssertTrue(open.waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(app.staticTexts["Investigate Mermaid tests"].firstMatch.waitForExistence(timeout: Self.timeout))
    }

    @MainActor
    func testWorkspaceProposalRetriesLostResponse() {
        let app = openAssistant(arguments: ["--demo-assistant-workspace-proposal", "--demo-workspace-proposal-retry"])
        let apply = app.buttons["proposal.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: Self.timeout))
        apply.tap()
        XCTAssertTrue(app.staticTexts["proposal.error"].waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(apply.label, "Retry")
        apply.tap()
        let outcome = app.staticTexts["proposal.outcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(outcome.label, "Workspace created")
        XCTAssertTrue(app.buttons["proposal.openWorkspace"].exists)
    }

    /// Taps land on the pill padding, outside the label glyphs, where the
    /// message's copy overlay used to claim them.
    @MainActor
    func testProposalButtonPaddingReceivesTaps() {
        let app = openAssistant(arguments: ["--demo-assistant-proposal"])
        let dismiss = app.buttons["proposal.dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: Self.timeout))
        tapPadding(of: dismiss)
        XCTAssertTrue(app.buttons["Dismiss proposal"].waitForExistence(timeout: Self.timeout))
    }

    @MainActor
    func testWorkspaceProposalButtonPaddingReceivesTaps() {
        let app = openAssistant(arguments: ["--demo-assistant-workspace-proposal"])
        let message = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "follow-up workspace for the Mermaid failures")
        ).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: Self.timeout))
        message.press(forDuration: 1)
        let copy = app.menuItems["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: Self.timeout), "Message text must keep its Copy menu")
        copy.tap()

        let dismiss = app.buttons["proposal.dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: Self.timeout))
        tapPadding(of: dismiss)
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: Self.timeout))
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: Self.timeout))

        let apply = app.buttons["proposal.apply"]
        tapPadding(of: apply)
        let outcome = app.staticTexts["proposal.outcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(outcome.label, "Workspace created")
        let open = app.buttons["proposal.openWorkspace"]
        XCTAssertTrue(open.exists)
        tapPadding(of: open)
        XCTAssertTrue(open.waitForNonExistence(timeout: Self.timeout))
    }

    /// Taps 8pt inside the leading edge at mid-height: within the 20pt
    /// horizontal padding and the pill's rounded shape.
    @MainActor
    private func tapPadding(of button: XCUIElement) {
        XCTAssertTrue(button.isHittable)
        button.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 8, dy: button.frame.height / 2))
            .tap()
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
        let launcher = app.buttons["intent.menu.open"]
        XCTAssertTrue(launcher.waitForExistence(timeout: Self.timeout))
        launcher.tap()
        let assistantTile = app.buttons["intent.menu.assistant"]
        XCTAssertTrue(assistantTile.waitForExistence(timeout: Self.timeout))
        assistantTile.tap()
        return app
    }
}
