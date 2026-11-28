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
        XCTAssertTrue(apply.appears(timeout: Self.timeout))
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
        XCTAssertTrue(outcome.appears(timeout: Self.timeout))
        XCTAssertEqual(outcome.label, "Applied")
        XCTAssertFalse(apply.exists)
    }

    @MainActor
    func testDismissProposal() {
        let app = openAssistant(arguments: ["--demo-assistant-proposal"])
        let dismiss = app.buttons["proposal.dismiss"]
        XCTAssertTrue(dismiss.appears(timeout: Self.timeout))
        dismiss.tap()
        app.buttons["Dismiss proposal"].tap()
        let outcome = app.staticTexts["proposal.outcome"]
        XCTAssertTrue(outcome.appears(timeout: Self.timeout))
        XCTAssertEqual(outcome.label, "Dismissed")
    }

    @MainActor
    func testStreamingMarkerStaysHiddenUntilWorkspaceCardIsReady() throws {
        let trigger = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-stream-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: trigger) }
        let app = openAssistant(arguments: ["--demo-workspace-stream-trigger=\(trigger.path)"])
        XCTAssertTrue(app.staticTexts["Workspace links are loading."].appears(timeout: Self.timeout))
        let raw = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "@@@")).firstMatch
        XCTAssertFalse(raw.exists)
        try Data().write(to: trigger)
        XCTAssertTrue(app.buttons["assistant.workspace.demo-ws-flaky-tests"].appears(timeout: Self.timeout))
        XCTAssertFalse(raw.exists)
    }

    @MainActor
    func testCreateWorkspaceFromProposalAndOpenIt() {
        let app = openAssistant(arguments: ["--demo-assistant-workspace-proposal"])
        let apply = app.buttons["proposal.apply"]
        XCTAssertTrue(apply.appears(timeout: Self.timeout))
        XCTAssertEqual(apply.label, "Create")
        captureSwitches(in: app, name: "Workspace proposal review")
        apply.tap()
        let outcome = app.staticTexts["proposal.outcome"]
        XCTAssertTrue(outcome.appears(timeout: Self.timeout))
        XCTAssertEqual(outcome.label, "Workspace created")
        let open = app.buttons["proposal.openWorkspace"]
        XCTAssertTrue(open.exists)
        captureSwitches(in: app, name: "Workspace proposal created")
        open.tap()
        XCTAssertTrue(open.disappears(timeout: Self.timeout))
        XCTAssertTrue(app.staticTexts["Investigate Mermaid tests"].firstMatch.appears(timeout: Self.timeout))
    }

    @MainActor
    func testWorkspaceProposalRetriesLostResponse() {
        let app = openAssistant(arguments: ["--demo-assistant-workspace-proposal", "--demo-workspace-proposal-retry"])
        let apply = app.buttons["proposal.apply"]
        XCTAssertTrue(apply.appears(timeout: Self.timeout))
        apply.tap()
        XCTAssertTrue(app.staticTexts["proposal.error"].appears(timeout: Self.timeout))
        XCTAssertEqual(apply.label, "Retry")
        apply.tap()
        let outcome = app.staticTexts["proposal.outcome"]
        XCTAssertTrue(outcome.appears(timeout: Self.timeout))
        XCTAssertEqual(outcome.label, "Workspace created")
        XCTAssertTrue(app.buttons["proposal.openWorkspace"].exists)
    }

    @MainActor
    func testProposalButtonPaddingReceivesTaps() {
        let app = openAssistant(arguments: ["--demo-assistant-proposal"])
        let dismiss = app.buttons["proposal.dismiss"]
        XCTAssertTrue(dismiss.appears(timeout: Self.timeout))
        tapPadding(of: dismiss)
        XCTAssertTrue(app.buttons["Dismiss proposal"].appears(timeout: Self.timeout))
    }

    @MainActor
    func testWorkspaceProposalMessageTextKeepsCopyMenu() {
        let app = openAssistant(arguments: ["--demo-assistant-workspace-proposal"])
        XCTAssertTrue(app.buttons["proposal.dismiss"].appears(timeout: Self.timeout))
        let message = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "follow-up workspace for the Mermaid failures")
        ).firstMatch
        XCTAssertTrue(message.appears(timeout: Self.timeout))
        message.press(forDuration: 1)
        let copy = app.menuItems["Copy"].firstMatch
        XCTAssertTrue(copy.appears(timeout: Self.timeout), "Message text must keep its Copy menu")
        copy.tap()
        XCTAssertTrue(copy.disappears(timeout: Self.timeout))
    }

    @MainActor
    func testWorkspaceProposalDismissPaddingReceivesTaps() {
        let app = openAssistant(arguments: ["--demo-assistant-workspace-proposal"])
        let dismiss = app.buttons["proposal.dismiss"]
        XCTAssertTrue(dismiss.appears(timeout: Self.timeout))
        tapPadding(of: dismiss)
        let confirm = app.buttons["Dismiss proposal"]
        XCTAssertTrue(confirm.appears(timeout: Self.timeout))
        confirm.tap()
        let outcome = app.staticTexts["proposal.outcome"]
        XCTAssertTrue(outcome.appears(timeout: Self.timeout))
        XCTAssertEqual(outcome.label, "Dismissed")
    }

    @MainActor
    func testWorkspaceProposalCreateAndOpenPaddingReceiveTaps() {
        let app = openAssistant(arguments: ["--demo-assistant-workspace-proposal"])
        let apply = app.buttons["proposal.apply"]
        XCTAssertTrue(apply.appears(timeout: Self.timeout))
        tapPadding(of: apply)
        let outcome = app.staticTexts["proposal.outcome"]
        XCTAssertTrue(outcome.appears(timeout: Self.timeout))
        XCTAssertEqual(outcome.label, "Workspace created")
        let open = app.buttons["proposal.openWorkspace"]
        XCTAssertTrue(open.exists)
        tapPadding(of: open)
        XCTAssertTrue(open.disappears(timeout: Self.timeout))
    }

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
        let app = XCUIApplication.intent()
        app.launchArguments += ["--demo-data"] + arguments
        app.launch()
        let launcher = app.buttons["intent.menu.open"]
        XCTAssertTrue(launcher.appears(timeout: Self.timeout))
        launcher.tap()
        let assistantTile = app.buttons["intent.menu.assistant"]
        XCTAssertTrue(assistantTile.appears(timeout: Self.timeout))
        assistantTile.tap()
        return app
    }
}
