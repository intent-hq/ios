import XCTest

enum ConnectionLossUITestFixture {
    static let timeout: TimeInterval = 15
    static let maximumCompactActionWidth: CGFloat = 0.75
    static let layoutTolerance: CGFloat = 2
    static let homeIdentifier = "connection-loss.home"
    static var navigationIdentifier: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad.rail.workspaces" : "intent.menu.open"
    }
    static let bannerIdentifier = "read-only-banner"
    static let bannerHomeIdentifier = "read-only-banner.home"
    static let leadingEdge: CGFloat = 0.1
    static let dragHold: TimeInterval = 0.1
    static let backNavigationAttempts = 3
    static let scrollAttempts = 6
    static let backNavigationTimeout: TimeInterval = 2
    static let stoppedReason = "This connection belongs to a different person. Pair again to choose that person."
    static let workspaceTitle = "Deflake payment integration tests"
    static let agentName = "Test Stabilizer"
}

nonisolated final class ConnectionLossUITests: XCTestCase {
    private typealias Fixture = ConnectionLossUITestFixture

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
        XCTAssertTrue(home.appears(timeout: Fixture.timeout))
        XCTAssertEqual(home.label, "Back to Home")
        home.tap()
        let saved = app.buttons["pairing.saved-connections"]
        XCTAssertTrue(saved.appears(timeout: Fixture.timeout))
        XCTAssertFalse(app.buttons[Fixture.bannerIdentifier].exists)
        capture(app, named: "source-after-home")
    }

    @MainActor
    func testDropKeepsConversationReadableAndRecoveryKeepsDraftAndNavigation() throws {
        let directory = try makeTriggerDirectory()
        let app = launch(directory: directory, arguments: ["--demo-connection-loss-reconnecting"])
        openConversation(in: app)
        let composer = app.textViews["composer.textView"]
        XCTAssertTrue(composer.appears(timeout: Fixture.timeout))
        composer.tap()
        composer.typeText("Draft survives ")
        capture(app, named: "conversation-before-loss")

        try trigger("loss", in: directory)
        assertBanner(in: app)
        XCTAssertTrue(composer.exists, "The conversation stays on screen while reconnecting")
        composer.typeText("connection loss")
        XCTAssertEqual(composer.value as? String, "Draft survives connection loss", "Typing stays enabled")
        let send = app.buttons["Send Message"].firstMatch
        XCTAssertTrue(send.exists)
        XCTAssertFalse(send.isEnabled, "Send must wait for the Mac")
        XCTAssertTrue(app.buttons["Add Attachment"].firstMatch.isEnabled, "Attaching stays enabled")
        capture(app, named: "conversation-read-only")

        try trigger("recover", in: directory)
        XCTAssertTrue(app.buttons[Fixture.bannerIdentifier].disappears(timeout: Fixture.timeout))
        XCTAssertEqual(composer.value as? String, "Draft survives connection loss")
        if UIDevice.current.userInterfaceIdiom != .pad {
            XCTAssertTrue(app.buttons["conversation.back"].exists, "Still in the same conversation")
        }
        let live = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [live], timeout: Fixture.timeout), .completed, "Send comes back with the Mac")
        capture(app, named: "conversation-recovered")
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
        XCTAssertTrue(saved.appears(timeout: Fixture.timeout))
        XCTAssertFalse(app.buttons[Fixture.homeIdentifier].exists)
        capture(app, named: "stopped-after-home")
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
        XCTAssertTrue(app.staticTexts["Can’t Connect"].appears(timeout: Fixture.timeout))
        XCTAssertTrue(app.staticTexts["Certificate mismatch"].exists)
        XCTAssertTrue(app.buttons["Re-pair Device"].exists)
        XCTAssertTrue(app.staticTexts["Allow Local Network access for Intent in Settings, then try again."].exists)
        XCTAssertFalse(app.buttons[Fixture.homeIdentifier].exists)
        try trigger("network-restored", in: directory)
        XCTAssertTrue(app.staticTexts["connection-network.status"].disappears(timeout: Fixture.timeout))
        XCTAssertTrue(app.staticTexts["Certificate mismatch"].exists)
        XCTAssertTrue(app.buttons["Re-pair Device"].isHittable)
        assertFailureBackReturnsHome(in: app, timeout: Fixture.timeout)
    }
}

extension ConnectionLossUITests {
    @MainActor
    func assertNetworkTitle(_ title: String, identifier: String, in app: XCUIApplication) {
        let text = app.staticTexts.matching(NSPredicate(
            format: "identifier == %@ AND label == %@", identifier, title
        )).firstMatch
        XCTAssertTrue(text.appears(timeout: Fixture.timeout))
    }

    @MainActor
    func assertStartupState(_ state: String, in app: XCUIApplication) {
        let status = app.staticTexts.matching(NSPredicate(
            format: "identifier == %@ AND label == %@", "demo-connection-startup", state
        )).firstMatch
        XCTAssertTrue(status.appears(timeout: Fixture.timeout), "Must observe the pending startup, not the workspace UI")
        XCTAssertFalse(app.buttons[Fixture.navigationIdentifier].exists)
        XCTAssertFalse(app.buttons[Fixture.homeIdentifier].exists)
    }

    @MainActor
    func launch(directory: URL, arguments: [String] = [], waitForStartup: Bool = true) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication.intent()
        app.launchArguments = ["--demo-data", "--demo-connection-loss-directory=" + directory.path] + arguments
        app.launch()
        let allowNotifications = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allowNotifications.appears(timeout: 2) {
            allowNotifications.tap()
        }
        if waitForStartup {
            XCTAssertTrue(app.buttons[Fixture.navigationIdentifier].appears(timeout: Fixture.timeout))
            XCTAssertFalse(app.buttons[Fixture.homeIdentifier].exists)
        }
        return app
    }

    @MainActor
    func openConversation(in app: XCUIApplication) {
        let workspace = app.staticTexts[Fixture.workspaceTitle].firstMatch
        XCTAssertTrue(workspace.appears(timeout: Fixture.timeout))
        workspace.tap()
        let agentsTab = app.buttons["workspace.content.Agents"]
        if agentsTab.appears(timeout: Fixture.backNavigationTimeout) { agentsTab.tap() }
        let agent = app.staticTexts[Fixture.agentName].firstMatch
        XCTAssertTrue(agent.appears(timeout: Fixture.timeout))
        agent.tap()
    }

    @MainActor
    func assertOverlay(in app: XCUIApplication) {
        let home = app.buttons[Fixture.homeIdentifier]
        XCTAssertTrue(home.appears(timeout: Fixture.timeout))
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
