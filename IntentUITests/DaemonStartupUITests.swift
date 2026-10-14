import XCTest

nonisolated final class DaemonStartupUITests: XCTestCase {
    private enum Fixture {
        static let timeout: TimeInterval = 20
        static let estimateMilliseconds = 12_000
        static let unchangedMilliseconds = 40_000
    }

    @MainActor func testInitialStartupCountsEstimateFinalizationAndFreshHello() throws {
        let peer = try StartupWebSocketFixture()
        defer { peer.stop() }
        try peer.setPhase("indexing")
        let app = launch(peer)
        assertTitle("Indexing Notes", app: app)
        XCTAssertTrue(app.staticTexts["daemon-startup.counts"].exists)
        XCTAssertFalse(app.staticTexts["daemon-startup.estimate"].exists)
        XCTAssertEqual(Set(peer.methods).subtracting(["client.hello", "system.startupStatus"]), [])
        capture(app, "startup-initial-unknown-estimate")
        try peer.setPhase("indexing", estimate: Fixture.estimateMilliseconds)
        XCTAssertTrue(app.staticTexts["daemon-startup.estimate"].waitForExistence(timeout: Fixture.timeout))
        capture(app, "startup-initial-estimate")
        try peer.setPhase("indexing", estimate: Fixture.estimateMilliseconds, age: Fixture.unchangedMilliseconds)
        XCTAssertTrue(app.staticTexts["daemon-startup.unchanged"].waitForExistence(timeout: Fixture.timeout))
        XCTAssertFalse(app.staticTexts["daemon-startup.estimate"].exists)
        capture(app, "startup-initial-unchanged")
        try peer.setPhase("finalizing")
        assertTitle("Finishing Startup", app: app)
        XCTAssertFalse(app.staticTexts["daemon-startup.estimate"].exists)
        XCTAssertFalse(app.staticTexts["daemon-startup.counts"].exists)
        XCTAssertFalse(peer.methods.contains("principal.me"))
        capture(app, "startup-initial-finalizing")
        try peer.setPhase("ready")
        waitForHydration(app)
        XCTAssertEqual(peer.acceptedCount, 2)
        XCTAssertEqual(peer.methods.filter { $0 == "client.hello" }.count, 2)
        XCTAssertTrue(peer.methods.contains("principal.me"))
        capture(app, "startup-ready-workspaces")
    }

    @MainActor func testReconnectUnavailableFailureAndRetry() throws {
        let peer = try StartupWebSocketFixture()
        defer { peer.stop() }
        let app = launch(peer, largeText: true)
        waitForHydration(app)
        try peer.setPhase("preparing")
        peer.dropConnections()
        assertTitle("Starting Desktop", app: app)
        XCTAssertTrue(app.buttons["connection-loss.home"].exists)
        capture(app, "startup-reconnect-preparing")
        try peer.setPhase("indexing", estimate: Fixture.estimateMilliseconds)
        assertTitle("Indexing Notes", app: app)
        capture(app, "startup-reconnect-indexing-large-text")
        let home = app.buttons["connection-loss.home"]
        if !home.isHittable {
            app.swipeUp()
            XCTAssertTrue(home.isHittable)
            app.swipeDown()
        }
        peer.holdStatus()
        XCTAssertTrue(app.staticTexts["daemon-startup.unavailable"].waitForExistence(timeout: Fixture.timeout))
        XCTAssertFalse(app.staticTexts["daemon-startup.counts"].exists)
        capture(app, "startup-reconnect-unavailable")
        try peer.setPhase("failed")
        assertTitle("Startup Failed", app: app)
        capture(app, "startup-reconnect-failed")
        try peer.setPhase(nil)
        app.buttons["daemon-startup.retry"].tap()
        waitForHydration(app)
        capture(app, "startup-reconnect-recovered")
    }

    @MainActor private func launch(_ peer: StartupWebSocketFixture, largeText: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in peer.port > 0 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: Fixture.timeout), .completed)
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["INTENT_STARTUP_TEST_PORT"] = String(peer.port)
        app.launchEnvironment["INTENT_STARTUP_TEST_PIN"] = StartupWebSocketFixture.fingerprint
        app.launch()
        let allowNotifications = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allowNotifications.waitForExistence(timeout: 2) { allowNotifications.tap() }
        return app
    }

    @MainActor private func assertTitle(_ expected: String, app: XCUIApplication) {
        let title = app.staticTexts["daemon-startup.title"]
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", expected), object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: Fixture.timeout), .completed)
    }

    @MainActor private func waitForHydration(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["workspace.row.demo-ws-reconnect"].waitForExistence(timeout: Fixture.timeout))
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["daemon-startup.title"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: Fixture.timeout), .completed)
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
