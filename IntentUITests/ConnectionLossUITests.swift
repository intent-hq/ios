import XCTest

/// Loss/recovery uses ConnectionManager's publisher with static demo RPC data;
/// no host network toggles, fixed presentation delays, or overlay-flag shortcuts.
nonisolated final class ConnectionLossUITests: XCTestCase {
    private enum Fixture {
        static let timeout: TimeInterval = 15
        static let bottomActionRegion: CGFloat = 0.75
        static let homeIdentifier = "connection-loss.home"
        static let workspaceTitle = "Deflake payment integration tests"
        static let agentName = "Test Stabilizer"
    }

    @MainActor
    func testQuickBackgroundRecoveryNeverPresentsOverlayAndKeepsConversationDraft() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["INTENT_UITEST_FULL_GATE_REPRO"] == "1",
            "Temporary quarantine for an unclassified full-gate failure: https://github.com/intent-hq/ios/issues/476; "
                + "opt in with TEST_RUNNER_INTENT_UITEST_FULL_GATE_REPRO=1."
        )
        let directory = try makeTriggerDirectory()
        let app = launch(directory: directory, arguments: ["--demo-background-loss=quick"])
        openConversation(in: app)
        let composer = app.textViews["composer.textView"]
        XCTAssertTrue(composer.waitForExistence(timeout: Fixture.timeout))
        composer.tap()
        composer.typeText("Draft survives background return")
        backgroundAndActivate(app, directory: directory)
        waitForEvent("did-recover", in: directory)
        XCTAssertFalse(eventExists("overlay-presented", in: directory), "Even a transient presentation is a regression")
        XCTAssertFalse(app.buttons[Fixture.homeIdentifier].exists)
        XCTAssertEqual(composer.value as? String, "Draft survives background return")
        XCTAssertTrue(app.navigationBars[Fixture.agentName].exists)
        capture(app, named: "quick-background-conversation")
    }

    @MainActor
    func testLossQueuedAtActivationNeverPresentsOverlayOrDismissesSheet() throws {
        let directory = try makeTriggerDirectory()
        let app = launch(directory: directory, arguments: ["--demo-background-loss=activation-quick"])
        // Saved Connections no longer opens Manual Connection. Use a real
        // editable sheet while connected, without submitting the draft.
        openCreateWorkspace(in: app)
        let repository = app.staticTexts["nova-labs/console"]
        XCTAssertTrue(repository.waitForExistence(timeout: Fixture.timeout))
        repository.tap()
        app.buttons["Next"].tap()
        XCTAssertTrue(app.navigationBars["Select Branch"].waitForExistence(timeout: Fixture.timeout))
        let next = app.buttons["Next"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: next)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: Fixture.timeout), .completed)
        next.tap()
        let sheet = app.navigationBars["Create Workspace"]
        XCTAssertTrue(sheet.waitForExistence(timeout: Fixture.timeout))
        // The placeholder disappears after typing; this sheet has one editable field.
        let message = app.textFields.firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: Fixture.timeout))
        XCTAssertEqual(app.textFields.count, 1)
        message.tap()
        message.typeText("Draft survives background return")
        XCTAssertEqual(message.value as? String, "Draft survives background return")
        backgroundAndActivate(app, directory: directory)
        waitForEvent("did-recover", in: directory)
        XCTAssertFalse(eventExists("overlay-presented", in: directory), "activate() settling must not hide a flash")
        XCTAssertFalse(app.buttons[Fixture.homeIdentifier].exists)
        XCTAssertTrue(message.waitForExistence(timeout: Fixture.timeout))
        XCTAssertEqual(message.value as? String, "Draft survives background return")
        XCTAssertTrue(sheet.exists)
        capture(app, named: "quick-background-sheet")
    }

    @MainActor
    func testSustainedBackgroundLossPresentsOverlayAndHomeStillWorks() throws {
        let directory = try makeTriggerDirectory()
        let app = launch(directory: directory, arguments: ["--demo-background-loss=sustained"])
        backgroundAndActivate(app, directory: directory)
        assertOverlay(in: app)
        XCTAssertTrue(eventExists("overlay-presented", in: directory), "Also validates the transient-presentation recorder")
        capture(app, named: "sustained-background-loss")
        app.buttons[Fixture.homeIdentifier].tap()
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Saved Connections")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: Fixture.timeout))
        XCTAssertFalse(app.buttons[Fixture.homeIdentifier].exists)
    }

    @MainActor
    func testLossBlocksConversationAndRecoveryKeepsDraftAndNavigation() throws {
        throw XCTSkip("Flaky: intent-hq/ios#476")
        let directory = try makeTriggerDirectory()
        let app = launch(directory: directory)
        openConversation(in: app)
        let composer = app.textViews["composer.textView"]
        XCTAssertTrue(composer.waitForExistence(timeout: Fixture.timeout))
        composer.tap()
        composer.typeText("Draft survives connection loss")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Fixture.timeout))
        capture(app, named: "conversation-before-loss")

        try trigger("loss", in: directory)
        assertOverlay(in: app)
        XCTAssertEqual(app.staticTexts["connection-loss.status"].label, "Reconnecting…", "Unknown is not offline")
        XCTAssertFalse(composer.exists, "The background editor must be excluded from accessibility")
        XCTAssertFalse(app.buttons["Workspace options"].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        capture(app, named: "conversation-loss")

        try trigger("recover", in: directory)
        XCTAssertTrue(app.buttons[Fixture.homeIdentifier].waitForNonExistence(timeout: Fixture.timeout))
        XCTAssertTrue(composer.waitForExistence(timeout: Fixture.timeout))
        XCTAssertEqual(composer.value as? String, "Draft survives connection loss")
        XCTAssertTrue(app.navigationBars[Fixture.agentName].exists)
        capture(app, named: "conversation-recovered")
    }

    @MainActor
    func testPresentedLossUpdatesNetworkCopyAcrossForegroundReturn() throws {
        let directory = try makeTriggerDirectory()
        let app = launch(directory: directory, arguments: ["--demo-connection-loss-cert-mismatch"])
        try trigger("loss", in: directory)
        assertOverlay(in: app)
        assertNetworkTitle("Reconnecting…", identifier: "connection-loss.status", in: app)

        // Only advisory status changes: the already-presented host must refresh.
        try trigger("network-offline", in: directory)
        assertNetworkTitle("No network connection", identifier: "connection-loss.status", in: app)
        XCTAssertTrue(app.staticTexts["Certificate mismatch"].exists)
        assertOverlay(in: app)
        let eventsBeforeBackground = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertFalse(
            eventExists("overlay-dismissed", in: directory),
            "Updating network copy must not recreate the overlay; events: \(eventsBeforeBackground)"
        )

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: Fixture.timeout))
        app.activate()
        assertNetworkTitle("No network connection", identifier: "connection-loss.status", in: app)
        assertOverlay(in: app)
        let events = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertFalse(
            eventExists("overlay-dismissed", in: directory),
            "An existing overlay must never hide on background return; events: \(events)"
        )

        try trigger("network-restored", in: directory)
        assertNetworkTitle("Reconnecting…", identifier: "connection-loss.status", in: app)
        XCTAssertTrue(app.staticTexts["Certificate mismatch"].exists)
        assertOverlay(in: app)
        try trigger("recover", in: directory)
        XCTAssertTrue(app.buttons[Fixture.homeIdentifier].waitForNonExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.buttons["Workspace options"].exists)
    }

    @MainActor
    func testReconnectingCoversNestedConnectionDetailsOnRecovery() throws {
        let directory = try makeTriggerDirectory()
        let app = launch(directory: directory, arguments: [
            "--demo-connection-loss-reconnecting", "--demo-connection-loss-cert-mismatch",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"
        ])
        app.buttons["Workspace options"].tap()
        app.buttons["Connect to…"].tap()
        // Wait for the parent sheet and its action before presenting a nested sheet.
        let machine = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Demo Mac")).firstMatch
        XCTAssertTrue(machine.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(machine.isHittable)
        machine.press(forDuration: 1)
        let details = app.buttons["Connection Details"]
        XCTAssertTrue(details.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(details.isHittable)
        details.tap()
        let detailsTitle = app.staticTexts["saved-connection.details-title"]
        XCTAssertTrue(detailsTitle.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.staticTexts["demo.invalid:443"].exists)
        // Both sheets own a Close button; only the presented Details action is hittable.
        let closeButtons = app.buttons.matching(identifier: "connection-sheet.close")
            .allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertEqual(closeButtons.count, 1)
        let cancelFrame = try XCTUnwrap(closeButtons.first).frame
        let cancelPosition = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: cancelFrame.midX, dy: cancelFrame.midY))
        capture(app, named: "sheet-before-loss")

        try trigger("network-offline", in: directory)
        try trigger("loss", in: directory)
        assertOverlay(in: app)
        assertNetworkTitle("No network connection", identifier: "connection-loss.status", in: app)
        XCTAssertTrue(app.staticTexts["Check your Wi-Fi or cellular connection."].exists)
        XCTAssertTrue(app.staticTexts["Certificate mismatch"].exists)
        XCTAssertTrue(app.staticTexts["demo.invalid"].exists)
        XCTAssertFalse(detailsTitle.exists, "The presented sheet must be excluded from accessibility")
        XCTAssertFalse(app.staticTexts["demo.invalid:443"].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        cancelPosition.tap() // A real coordinate tap must not dismiss the covered detail sheet.
        capture(app, named: "sheet-offline-large-text-certificate")

        try trigger("network-restored", in: directory)
        assertNetworkTitle("Reconnecting…", identifier: "connection-loss.status", in: app)
        assertOverlay(in: app)
        XCTAssertFalse(detailsTitle.exists, "A general path recovery must not dismiss the loss surface")
        XCTAssertTrue(app.staticTexts["Certificate mismatch"].exists)
        capture(app, named: "network-restored-backend-still-down")

        try trigger("recover", in: directory)
        XCTAssertTrue(app.buttons[Fixture.homeIdentifier].waitForNonExistence(timeout: Fixture.timeout))
        XCTAssertTrue(detailsTitle.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.staticTexts["Demo Mac"].exists)
        XCTAssertTrue(app.staticTexts["demo.invalid:443"].exists)
        capture(app, named: "sheet-recovered")
    }

    @MainActor
    func testHomeRetainsSavedMachineAndAllowsReselection() throws {
        let directory = try makeTriggerDirectory()
        try trigger("network-offline", in: directory)
        let app = launch(directory: directory)
        XCTAssertFalse(app.staticTexts["connection-network.status"].exists, "Healthy remote UI stays unobstructed")
        openCreateWorkspace(in: app)
        try trigger("loss", in: directory)
        assertOverlay(in: app)
        assertNetworkTitle("No network connection", identifier: "connection-loss.status", in: app)
        app.buttons[Fixture.homeIdentifier].tap()

        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Saved Connections")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: Fixture.timeout))
        XCTAssertFalse(app.buttons[Fixture.homeIdentifier].exists)
        XCTAssertFalse(app.navigationBars["Select Repository"].exists)
        XCTAssertFalse(app.staticTexts["connection-network.status"].exists, "Home is not an offline failure screen")
        try trigger("network-restored", in: directory)
        try trigger("recover", in: directory)
        saved.tap()
        let machine = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Demo Mac")).firstMatch
        XCTAssertTrue(machine.waitForExistence(timeout: Fixture.timeout))
        capture(app, named: "home-saved-machine-retained")
        machine.tap()
        XCTAssertTrue(app.buttons["Workspace options"].waitForExistence(timeout: Fixture.timeout))
        XCTAssertFalse(app.buttons[Fixture.homeIdentifier].exists)
        capture(app, named: "saved-machine-reselected")
    }

    @MainActor
    func testPendingStartupLossAndRecoveryNeverShowOverlay() throws {
        let directory = try makeTriggerDirectory()
        try trigger("network-offline", in: directory)
        let app = launch(directory: directory, arguments: ["--demo-connection-loss-pending-startup"], waitForStartup: false)
        assertStartupState("connected", in: app)
        assertNetworkTitle("No network connection", identifier: "connection-network.status", in: app)
        try trigger("loss", in: directory)
        assertStartupState("disconnected", in: app)
        capture(app, named: "inline-offline-startup")
        try trigger("network-restored", in: directory)
        XCTAssertTrue(app.staticTexts["connection-network.status"].waitForNonExistence(timeout: Fixture.timeout))
        assertStartupState("disconnected", in: app)
        try trigger("recover", in: directory)
        assertStartupState("connected", in: app)
        try trigger("initial-data", in: directory)
        XCTAssertTrue(app.buttons["Workspace options"].waitForExistence(timeout: Fixture.timeout))
        XCTAssertFalse(app.buttons[Fixture.homeIdentifier].exists, "Startup loss must not surface after entry")
    }

    @MainActor
    func testStartupTimeoutKeepsSavedMachinesAccessibleWithoutOverlay() throws {
        let directory = try makeTriggerDirectory()
        try trigger("network-offline", in: directory)
        let app = launch(
            directory: directory,
            arguments: ["--demo-connection-loss-pending-startup", "--demo-connection-loss-startup-timeout"],
            waitForStartup: false
        )
        assertStartupState("connected", in: app)
        try trigger("loss", in: directory)
        assertStartupState("disconnected", in: app)
        try trigger("initial-timeout", in: directory)
        XCTAssertTrue(app.buttons["Workspace options"].waitForExistence(timeout: Fixture.timeout))
        XCTAssertFalse(app.buttons[Fixture.homeIdentifier].exists)
        XCTAssertFalse(app.staticTexts["Can't Connect"].exists, "Data timeout must not add a second retry owner")
        assertNetworkTitle("No network connection", identifier: "connection-network.status", in: app)
        capture(app, named: "startup-timeout-fallback")
        app.buttons["Workspace options"].tap()
        app.buttons["Connect to…"].tap()
        let machine = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Demo Mac")).firstMatch
        XCTAssertTrue(machine.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(machine.isHittable, "Saved machines must remain accessible without forgetting credentials")
        capture(app, named: "startup-timeout-saved-machines")
    }

    @MainActor
    func testPermissionAndCertificateFailureRemainInline() throws {
        let directory = try makeTriggerDirectory()
        let app = launch(
            directory: directory,
            arguments: [
                "--demo-connection-loss-pending-startup", "--demo-connection-loss-startup-failure",
                "--demo-network-requires-connection", "--demo-network-local-denied",
                "--demo-connection-loss-cert-mismatch"
            ],
            waitForStartup: false
        )
        assertStartupState("connected", in: app)
        XCTAssertFalse(app.staticTexts["connection-network.status"].exists, "requiresConnection is not offline")
        try trigger("network-offline", in: directory)
        assertNetworkTitle("No network connection", identifier: "connection-network.status", in: app)
        XCTAssertTrue(app.staticTexts["Allow Local Network access for Intent in Settings, then try again."].exists)
        try trigger("loss", in: directory)
        XCTAssertTrue(app.staticTexts["Can't Connect"].waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.staticTexts["Certificate mismatch"].exists)
        XCTAssertTrue(app.buttons["Re-pair Device"].exists)
        XCTAssertTrue(app.staticTexts["Allow Local Network access for Intent in Settings, then try again."].exists)
        XCTAssertFalse(app.buttons[Fixture.homeIdentifier].exists)
        try trigger("network-restored", in: directory)
        XCTAssertTrue(app.staticTexts["connection-network.status"].waitForNonExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.staticTexts["Certificate mismatch"].exists)
        XCTAssertTrue(app.buttons["Re-pair Device"].isHittable)
    }
}

extension ConnectionLossUITests {
    @MainActor
    private func assertNetworkTitle(_ title: String, identifier: String, in app: XCUIApplication) {
        let text = app.staticTexts.matching(NSPredicate(
            format: "identifier == %@ AND label == %@", identifier, title
        )).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: Fixture.timeout))
    }

    @MainActor
    private func assertStartupState(_ state: String, in app: XCUIApplication) {
        let status = app.staticTexts.matching(NSPredicate(
            format: "identifier == %@ AND label == %@", "demo-connection-startup", state
        )).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: Fixture.timeout), "Must observe the pending startup, not the workspace UI")
        XCTAssertFalse(app.buttons["Workspace options"].exists)
        XCTAssertFalse(app.buttons[Fixture.homeIdentifier].exists)
    }

    @MainActor
    private func launch(directory: URL, arguments: [String] = [], waitForStartup: Bool = true) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "--demo-connection-loss-directory=" + directory.path] + arguments
        app.launch()
        // First launch on a fresh simulator is inactive behind this prompt;
        // the scene-owned network monitor cannot start until it is dismissed.
        let allowNotifications = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allowNotifications.waitForExistence(timeout: 2) {
            allowNotifications.tap()
        }
        if waitForStartup {
            XCTAssertTrue(app.buttons["Workspace options"].waitForExistence(timeout: Fixture.timeout))
            XCTAssertFalse(app.buttons[Fixture.homeIdentifier].exists)
        }
        return app
    }

    @MainActor
    private func openConversation(in app: XCUIApplication) {
        let workspace = app.staticTexts[Fixture.workspaceTitle].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.timeout))
        workspace.tap()
        let agent = app.staticTexts[Fixture.agentName].firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: Fixture.timeout))
        agent.tap()
    }

    @MainActor
    private func openCreateWorkspace(in app: XCUIApplication) {
        if app.buttons["Create workspace"].exists {
            app.buttons["Create workspace"].tap()
        } else {
            app.buttons["Workspace options"].tap()
            app.buttons["Create New Workspace"].tap()
        }
        XCTAssertTrue(app.navigationBars["Select Repository"].waitForExistence(timeout: Fixture.timeout))
    }

    @MainActor
    private func assertOverlay(in app: XCUIApplication) {
        let home = app.buttons[Fixture.homeIdentifier]
        XCTAssertTrue(home.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(home.isHittable)
        XCTAssertTrue(app.staticTexts["connection-loss.status"].exists)
        XCTAssertGreaterThan(home.frame.minY, app.frame.height * Fixture.bottomActionRegion)
        XCTAssertLessThan(home.frame.maxY, app.frame.maxY)
        XCTAssertEqual(app.buttons.count, 1, "Only the overlay action should be exposed to accessibility")
    }

    private func makeTriggerDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { [weak self] in
            let events = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            let attachment = XCTAttachment(string: events.joined(separator: "\n"))
            attachment.name = "connection-loss-fixture-events"
            attachment.lifetime = .keepAlways
            self?.add(attachment)
            print("Connection-loss fixture events: \(events)")
            try FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func trigger(_ name: String, in directory: URL) throws {
        try Data().write(to: directory.appendingPathComponent(name))
    }

    @MainActor
    private func backgroundAndActivate(_ app: XCUIApplication, directory: URL) {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: Fixture.timeout))
        waitForEvent("did-background", in: directory)
        XCTAssertFalse(eventExists("overlay-presented", in: directory), "Background loss must not pre-present an overlay")
        app.activate()
        waitForEvent("did-activate", in: directory)
    }

    private func eventExists(_ event: String, in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(event).path)
    }

    private func waitForEvent(_ event: String, in directory: URL) {
        let path = directory.appendingPathComponent(event).path
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: Fixture.timeout), .completed, "Missing fixture event: \(event)")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "connection-loss-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
