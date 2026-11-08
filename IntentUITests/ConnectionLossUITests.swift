import XCTest

/// Shared by the connection-loss UI test files.
enum ConnectionLossUITestFixture {
    static let timeout: TimeInterval = 15
    static let maximumCompactActionWidth: CGFloat = 0.75
    static let layoutTolerance: CGFloat = 2
    static let homeIdentifier = "connection-loss.home"
    /// The always-present navigation control once the remote UI is up.
    static var navigationIdentifier: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad.rail.workspaces" : "intent.menu.open"
    }
    static let bannerIdentifier = "read-only-banner"
    static let bannerHomeIdentifier = "read-only-banner.home"
    static let horizontalCenter: CGFloat = 0.5
    static let upperArea: CGFloat = 0.3
    static let leadingEdge: CGFloat = 0.1
    static let lowerMiddle: CGFloat = 0.6
    static let bottomEdge: CGFloat = 0.95
    static let dragHold: TimeInterval = 0.1
    static let readOnlyTapPoint = CGVector(dx: horizontalCenter, dy: upperArea)
    static let menuDismissPoint = CGVector(dx: leadingEdge, dy: lowerMiddle)
    static let sheetDismissPoint = CGVector(dx: horizontalCenter, dy: bottomEdge)
    static let backNavigationAttempts = 3
    static let scrollAttempts = 6
    /// Padding between the banner's text row and the edge of its pill.
    static let bannerPadding: CGFloat = 8
    static let backNavigationTimeout: TimeInterval = 2
    static let stoppedReason = "This connection belongs to a different person. Pair again to choose that person."
    static let workspaceTitle = "Deflake payment integration tests"
    static let agentName = "Test Stabilizer"
}

/// Loss/recovery uses ConnectionManager's publisher with static demo RPC data;
/// no host network toggles, fixed presentation delays, or overlay-flag shortcuts.
nonisolated final class ConnectionLossUITests: XCTestCase {
    private typealias Fixture = ConnectionLossUITestFixture

    @MainActor
    func testQuickBackgroundRecoveryNeverPresentsBannerAndKeepsConversationDraft() throws {
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
        XCTAssertFalse(eventExists("banner-presented", in: directory), "Even a transient banner is a regression")
        XCTAssertFalse(eventExists("overlay-presented", in: directory))
        XCTAssertFalse(app.buttons[Fixture.bannerIdentifier].exists)
        XCTAssertEqual(composer.value as? String, "Draft survives background return")
        XCTAssertTrue(app.navigationBars[Fixture.agentName].exists)
        capture(app, named: "quick-background-conversation")
    }

    @MainActor
    func testLossQueuedAtActivationNeverPresentsBannerOrDismissesSheet() throws {
        let directory = try makeTriggerDirectory()
        let app = launch(directory: directory, arguments: ["--demo-background-loss=activation-quick"])
        // Saved Connections no longer opens Manual Connection. Use a real
        // editable sheet while connected, without submitting the draft.
        openCreateWorkspace(in: app)
        let repository = app.staticTexts["nova-labs/console"]
        XCTAssertTrue(repository.waitForExistence(timeout: Fixture.timeout))
        repository.tap()
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["creation.branchTitle"].waitForExistence(timeout: Fixture.timeout))
        let next = app.buttons["Next"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: next)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: Fixture.timeout), .completed)
        next.tap()
        let sheet = app.buttons["creation.back"]
        XCTAssertTrue(sheet.waitForExistence(timeout: Fixture.timeout))
        // The identifier remains stable after typing; this sheet has one editable field.
        let message = app.textViews["creation.prompt"]
        XCTAssertTrue(message.waitForExistence(timeout: Fixture.timeout))
        XCTAssertEqual(app.textViews.count, 1)
        message.tap()
        message.typeText("Draft survives background return")
        XCTAssertEqual(message.value as? String, "Draft survives background return")
        backgroundAndActivate(app, directory: directory)
        waitForEvent("did-recover", in: directory)
        XCTAssertFalse(eventExists("banner-presented", in: directory), "activate() settling must not hide a banner flash")
        XCTAssertFalse(eventExists("overlay-presented", in: directory))
        XCTAssertFalse(app.buttons[Fixture.bannerIdentifier].exists)
        XCTAssertTrue(message.waitForExistence(timeout: Fixture.timeout))
        XCTAssertEqual(message.value as? String, "Draft survives background return")
        XCTAssertTrue(sheet.exists)
        capture(app, named: "quick-background-sheet")
    }

    @MainActor
    func testSustainedBackgroundLossShowsBannerAndHomeStillWorks() throws {
        let directory = try makeTriggerDirectory()
        let app = launch(directory: directory, arguments: ["--demo-background-loss=sustained"])
        backgroundAndActivate(app, directory: directory)
        let banner = assertBanner(in: app)
        XCTAssertTrue(eventExists("banner-presented", in: directory), "Also validates the transient-presentation recorder")
        XCTAssertFalse(eventExists("overlay-presented", in: directory), "A drop that keeps reconnecting never blocks")
        XCTAssertTrue(app.buttons[Fixture.navigationIdentifier].isHittable, "The page below stays usable")
        capture(app, named: "sustained-background-banner")
        banner.tap()
        let home = app.buttons[Fixture.bannerHomeIdentifier]
        XCTAssertTrue(home.waitForExistence(timeout: Fixture.timeout))
        XCTAssertEqual(home.label, "Back to Home")
        home.tap()
        let saved = app.buttons["pairing.saved-connections"]
        XCTAssertTrue(saved.waitForExistence(timeout: Fixture.timeout))
        XCTAssertFalse(app.buttons[Fixture.bannerIdentifier].exists)
        capture(app, named: "source-after-home")
    }

    @MainActor
    func testDropKeepsConversationReadableAndRecoveryKeepsDraftAndNavigation() throws {
        let directory = try makeTriggerDirectory()
        let app = launch(directory: directory, arguments: ["--demo-connection-loss-reconnecting"])
        openConversation(in: app)
        let composer = app.textViews["composer.textView"]
        XCTAssertTrue(composer.waitForExistence(timeout: Fixture.timeout))
        composer.tap()
        composer.typeText("Draft survives ")
        capture(app, named: "conversation-before-loss")

        try trigger("loss", in: directory)
        assertBanner(in: app)
        XCTAssertTrue(composer.exists, "The conversation stays on screen while reconnecting")
        composer.typeText("connection loss")
        XCTAssertEqual(composer.value as? String, "Draft survives connection loss", "Typing stays enabled")
        let send = app.buttons["Send message"].firstMatch
        XCTAssertTrue(send.exists)
        XCTAssertFalse(send.isEnabled, "Send must wait for the Mac")
        XCTAssertTrue(app.buttons["Add attachment"].firstMatch.isEnabled, "Attaching stays enabled")
        capture(app, named: "conversation-read-only")

        try trigger("recover", in: directory)
        XCTAssertTrue(app.buttons[Fixture.bannerIdentifier].waitForNonExistence(timeout: Fixture.timeout))
        XCTAssertEqual(composer.value as? String, "Draft survives connection loss")
        // iPad shows the conversation beside the sidebar, without a Back button.
        if UIDevice.current.userInterfaceIdiom != .pad {
            XCTAssertTrue(app.buttons["conversation.back"].exists, "Still in the same conversation")
        }
        let live = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [live], timeout: Fixture.timeout), .completed, "Send comes back with the Mac")
        capture(app, named: "conversation-recovered")
    }

    @MainActor
    func testBannerUpdatesNetworkCopyAcrossForegroundReturn() throws {
        let directory = try makeTriggerDirectory()
        let app = launch(directory: directory, arguments: [
            "--demo-connection-loss-reconnecting", "--demo-connection-loss-cert-mismatch", "--demo-network-local-denied"
        ])
        try trigger("loss", in: directory)
        assertBannerTitle("Reconnecting( to Demo Mac)?… · Read-only", in: app)

        // Only advisory status changes: the presented banner must refresh in place.
        try trigger("network-offline", in: directory)
        assertBannerTitle("Local Network access needed · Read-only", in: app)
        app.buttons[Fixture.bannerIdentifier].tap()
        XCTAssertTrue(app.staticTexts["Allow Local Network access for Intent in Settings, then try again."].waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.staticTexts["Certificate mismatch"].exists)
        capture(app, named: "banner-permission-and-certificate")
        XCTAssertFalse(eventExists("banner-dismissed", in: directory), "Updating copy must not recreate the banner")

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: Fixture.timeout))
        app.activate()
        assertBannerTitle("Local Network access needed · Read-only", in: app)
        XCTAssertFalse(eventExists("banner-dismissed", in: directory), "A banner must never hide on background return")

        try trigger("network-restored", in: directory)
        assertBannerTitle("Reconnecting( to Demo Mac)?… · Read-only", in: app)
        try trigger("recover", in: directory)
        XCTAssertTrue(app.buttons[Fixture.bannerIdentifier].waitForNonExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.buttons[Fixture.navigationIdentifier].exists)
    }

    @MainActor
    func testSheetOpenDuringDropStaysUsableUnderTheBanner() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "The Connections sheet is a popover on iPad")
        let directory = try makeTriggerDirectory()
        let app = launch(directory: directory, arguments: [
            "--demo-connection-loss-reconnecting", "--demo-connection-loss-cert-mismatch",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"
        ])
        app.openHomeAction("connections")
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
        capture(app, named: "sheet-before-loss")
        let titleBeforeLoss = detailsTitle.frame.minY

        try trigger("network-offline", in: directory)
        try trigger("loss", in: directory)
        let banner = assertBanner(in: app)
        assertBannerTitle("No network connection · Read-only", in: app)
        XCTAssertTrue(detailsTitle.exists, "A drop must not dismiss or hide the open sheet")
        XCTAssertTrue(app.staticTexts["demo.invalid:443"].exists)
        XCTAssertLessThan(banner.frame.minY, detailsTitle.frame.minY, "The banner stays on top of the sheet")
        // The partial-height sheet starts below the banner, so it gets no empty band.
        XCTAssertEqual(detailsTitle.frame.minY, titleBeforeLoss, accuracy: Fixture.layoutTolerance, "The sheet must not move down under the banner")
        capture(app, named: "sheet-offline-banner")
        banner.tap()
        XCTAssertTrue(app.staticTexts["Check your Wi-Fi or cellular connection."].waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.staticTexts["Certificate mismatch"].exists)
        XCTAssertTrue(app.buttons[Fixture.bannerHomeIdentifier].isHittable)
        capture(app, named: "sheet-offline-banner-expanded")

        try trigger("network-restored", in: directory)
        try trigger("recover", in: directory)
        XCTAssertTrue(banner.waitForNonExistence(timeout: Fixture.timeout))
        XCTAssertTrue(detailsTitle.exists)
        XCTAssertTrue(app.staticTexts["demo.invalid:443"].exists)
        capture(app, named: "sheet-recovered")
    }

    @MainActor
    func testStoppedReconnectionBlocksWithReasonAndHomeWorks() throws {
        let directory = try makeTriggerDirectory()
        let app = launch(directory: directory, arguments: ["--demo-connection-loss-stopped"])
        capture(app, named: "source-before-stop")
        let sourceImage = app.screenshot().image
        try trigger("loss", in: directory)
        assertOverlay(in: app)
        XCTAssertFalse(app.buttons[Fixture.bannerIdentifier].exists, "A stopped reconnection blocks instead")
        assertStoppedTitle(in: app)
        XCTAssertEqual(app.staticTexts["connection-loss.message"].label, Fixture.stoppedReason)
        XCTAssertEqual(app.buttons[Fixture.homeIdentifier].label, "Back to Home")
        XCTAssertLessThan(app.buttons[Fixture.homeIdentifier].frame.width, app.frame.width * Fixture.maximumCompactActionWidth)
        XCTAssertEqual(app.buttons[Fixture.homeIdentifier].frame.midX, app.frame.midX, accuracy: Fixture.layoutTolerance)
        XCTAssertTrue(eventExists("overlay-presented", in: directory))
        capture(app, named: "stopped-reconnection")
        try assertConnectionLossSubtitleContrast(in: app, sourceImage: sourceImage)
        app.buttons[Fixture.homeIdentifier].tap()
        let saved = app.buttons["pairing.saved-connections"]
        XCTAssertTrue(saved.waitForExistence(timeout: Fixture.timeout))
        XCTAssertFalse(app.buttons[Fixture.homeIdentifier].exists)
        capture(app, named: "stopped-after-home")
    }

    @MainActor
    func testHomeRetainsSavedMachineAndAllowsReselection() throws {
        let directory = try makeTriggerDirectory()
        try trigger("network-offline", in: directory)
        let app = launch(directory: directory, arguments: ["--demo-connection-loss-stopped"])
        XCTAssertFalse(app.staticTexts["connection-network.status"].exists, "Healthy remote UI stays unobstructed")
        openCreateWorkspace(in: app)
        try trigger("loss", in: directory)
        assertOverlay(in: app)
        assertStoppedTitle(in: app)
        XCTAssertTrue(app.staticTexts["Check your Wi-Fi or cellular connection."].exists)
        app.buttons[Fixture.homeIdentifier].tap()

        let saved = app.buttons["pairing.saved-connections"]
        XCTAssertTrue(saved.waitForExistence(timeout: Fixture.timeout))
        XCTAssertFalse(app.buttons[Fixture.homeIdentifier].exists)
        XCTAssertFalse(app.staticTexts["creation.repositoryTitle"].exists)
        XCTAssertFalse(app.staticTexts["connection-network.status"].exists, "Home is not an offline failure screen")
        try trigger("network-restored", in: directory)
        try trigger("recover", in: directory)
        saved.tap()
        let machine = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Demo Mac")).firstMatch
        XCTAssertTrue(machine.waitForExistence(timeout: Fixture.timeout))
        capture(app, named: "home-saved-machine-retained")
        machine.tap()
        XCTAssertTrue(app.buttons[Fixture.navigationIdentifier].waitForExistence(timeout: Fixture.timeout))
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
        XCTAssertTrue(app.buttons[Fixture.navigationIdentifier].waitForExistence(timeout: Fixture.timeout))
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
        XCTAssertTrue(app.buttons[Fixture.navigationIdentifier].waitForExistence(timeout: Fixture.timeout))
        XCTAssertFalse(app.buttons[Fixture.homeIdentifier].exists)
        XCTAssertFalse(app.staticTexts["Can’t Connect"].exists, "Data timeout must not add a second retry owner")
        assertNetworkTitle("No network connection", identifier: "connection-network.status", in: app)
        capture(app, named: "startup-timeout-fallback")
        app.openHomeAction("connections")
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
        XCTAssertTrue(app.staticTexts["Can’t Connect"].waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.staticTexts["Certificate mismatch"].exists)
        XCTAssertTrue(app.buttons["Re-pair Device"].exists)
        XCTAssertTrue(app.staticTexts["Allow Local Network access for Intent in Settings, then try again."].exists)
        XCTAssertFalse(app.buttons[Fixture.homeIdentifier].exists)
        try trigger("network-restored", in: directory)
        XCTAssertTrue(app.staticTexts["connection-network.status"].waitForNonExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.staticTexts["Certificate mismatch"].exists)
        XCTAssertTrue(app.buttons["Re-pair Device"].isHittable)
        assertFailureBackReturnsHome(in: app, timeout: Fixture.timeout)
    }
}

extension ConnectionLossUITests {
    @MainActor
    func testLargestTextCanScrollToWarningsAndHome() throws {
        let directory = try makeTriggerDirectory()
        let app = launch(directory: directory, arguments: [
            "--demo-connection-loss-cert-mismatch",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        try trigger("network-offline", in: directory)
        try trigger("loss", in: directory)
        let home = app.buttons[Fixture.homeIdentifier]
        XCTAssertTrue(home.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.staticTexts["Check your Wi-Fi or cellular connection."].exists)
        capture(app, named: "largest-text-before-scroll")
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(app.staticTexts["Certificate mismatch"].isHittable)
        XCTAssertTrue(home.isHittable)
        capture(app, named: "largest-text-home-visible")
        home.tap()
        let saved = app.buttons["pairing.saved-connections"]
        XCTAssertTrue(saved.waitForExistence(timeout: Fixture.timeout))
        XCTAssertFalse(home.exists)
    }

    @MainActor
    func assertNetworkTitle(_ title: String, identifier: String, in app: XCUIApplication) {
        let text = app.staticTexts.matching(NSPredicate(
            format: "identifier == %@ AND label == %@", identifier, title
        )).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: Fixture.timeout))
    }

    @MainActor
    func assertStartupState(_ state: String, in app: XCUIApplication) {
        let status = app.staticTexts.matching(NSPredicate(
            format: "identifier == %@ AND label == %@", "demo-connection-startup", state
        )).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: Fixture.timeout), "Must observe the pending startup, not the workspace UI")
        XCTAssertFalse(app.buttons[Fixture.navigationIdentifier].exists)
        XCTAssertFalse(app.buttons[Fixture.homeIdentifier].exists)
    }

    @MainActor
    func launch(directory: URL, arguments: [String] = [], waitForStartup: Bool = true) -> XCUIApplication {
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
            XCTAssertTrue(app.buttons[Fixture.navigationIdentifier].waitForExistence(timeout: Fixture.timeout))
            XCTAssertFalse(app.buttons[Fixture.homeIdentifier].exists)
        }
        return app
    }

    @MainActor
    func openConversation(in app: XCUIApplication) {
        let workspace = app.staticTexts[Fixture.workspaceTitle].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.timeout))
        workspace.tap()
        // The workspace page restores its last tab; agents live on Agents.
        let agentsTab = app.buttons["workspace.content.Agents"]
        if agentsTab.waitForExistence(timeout: Fixture.backNavigationTimeout) { agentsTab.tap() }
        let agent = app.staticTexts[Fixture.agentName].firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: Fixture.timeout))
        agent.tap()
    }

    @MainActor
    func openCreateWorkspace(in app: XCUIApplication) {
        app.openHomeAction("workspace")
        XCTAssertTrue(app.staticTexts["creation.repositoryTitle"].waitForExistence(timeout: Fixture.timeout))
    }

    @MainActor
    func assertOverlay(in app: XCUIApplication) {
        let home = app.buttons[Fixture.homeIdentifier]
        XCTAssertTrue(home.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(home.isHittable)
        XCTAssertTrue(app.staticTexts["connection-loss.status"].exists)
        XCTAssertGreaterThan(home.frame.minY, app.staticTexts["connection-loss.message"].frame.maxY)
        XCTAssertLessThan(home.frame.maxY, app.frame.maxY)
        XCTAssertEqual(app.buttons.count, 1, "Only the overlay action should be exposed to accessibility")
    }

    func makeTriggerDirectory() throws -> URL {
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

    func trigger(_ name: String, in directory: URL) throws {
        try Data().write(to: directory.appendingPathComponent(name))
    }

    @MainActor
    func backgroundAndActivate(_ app: XCUIApplication, directory: URL) {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: Fixture.timeout))
        waitForEvent("did-background", in: directory)
        XCTAssertFalse(eventExists("overlay-presented", in: directory), "Background loss must not pre-present an overlay")
        app.activate()
        waitForEvent("did-activate", in: directory)
    }

    func eventExists(_ event: String, in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(event).path)
    }

    func waitForEvent(_ event: String, in directory: URL) {
        let path = directory.appendingPathComponent(event).path
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: Fixture.timeout), .completed, "Missing fixture event: \(event)")
    }
}
