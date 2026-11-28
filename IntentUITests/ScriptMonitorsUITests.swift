import UIKit
import XCTest

nonisolated final class ScriptMonitorsUITests: XCTestCase {
    private static let timeout: TimeInterval = 15
    private static let rowID = "script-monitor-demo-script-watch-owned"
    private static let originalName = "Build verification — long script name with 日本語 and accessibility context"
    private static let updatedName = "Renamed verification — same watch and run"

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        continueAfterFailure = true
        try super.tearDownWithError()
    }

    @MainActor
    func testOwnedWatchDetailsUpdateAndRemovalWithoutRestart() throws {
        let directory = try fixtureDirectory()
        let app = launch(directory: directory)
        let row = app.buttons[Self.rowID]
        XCTAssertTrue(row.appears(timeout: Self.timeout))
        XCTAssertTrue(row.label.contains(Self.originalName), "VoiceOver must retain the full untruncated name")
        XCTAssertEqual((row.value as? String)?.contains("Watch expires"), true)
        XCTAssertFalse(app.buttons["script-monitor-demo-script-watch-other-owner"].exists)
        XCTAssertEqual(try requests(directory).filter { $0 == "scriptMonitor.list" }.count, 1)
        XCTAssertFalse(try requests(directory).contains("scriptMonitor.get"), "Summary hydration must not fetch details")
        capture(app, "script-monitors-active")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["script-monitor-details"].firstMatch.appears(timeout: Self.timeout))
        assertDetailText(app, "demo-script-build-check")
        assertDetailText(app, "demo-run-watched-original")
        assertDetailText(app, "Continue Spec Writer")
        assertDetailText(app, "[0-9]+$")
        XCTAssertEqual(try requests(directory).filter { $0 == "scriptMonitor.get" }.count, 1)
        capture(app, "script-monitors-details")
        closeDetails(app)

        try trigger("rename", directory: directory)
        let renamed = NSPredicate(format: "label CONTAINS %@", Self.updatedName)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: renamed, object: row)], timeout: Self.timeout), .completed)
        XCTAssertEqual(app.state, .runningForeground)
        capture(app, "script-monitors-text-update")
        row.tap()
        try trigger("completed", directory: directory)
        assertDetailText(app, "This watch is no longer available")
        capture(app, "script-monitors-removed-details")
        closeDetails(app)
        XCTAssertTrue(row.disappears(timeout: Self.timeout))
        XCTAssertFalse(app.buttons["script-monitor-demo-script-watch-other-owner"].exists)
        XCTAssertEqual(try requests(directory).filter { $0 == "scriptMonitor.list" }.count, 1, "Complete events must update locally")
        capture(app, "script-monitors-removed")
    }

    @MainActor
    func testLoadingFailureRetriesWithoutInventingAnEmptyState() throws {
        let directory = try fixtureDirectory()
        let app = launch(directory: directory, scenario: "retry")
        XCTAssertTrue(app.descendants(matching: .any)["script-monitors-loading"].firstMatch.appears(timeout: Self.timeout))
        XCTAssertFalse(app.buttons[Self.rowID].exists)
        capture(app, "script-monitors-loading")
        try trigger("list-ready", directory: directory)
        let retry = app.buttons["script-monitors-retry"]
        XCTAssertTrue(retry.appears(timeout: Self.timeout))
        capture(app, "script-monitors-error")
        retry.tap()
        XCTAssertTrue(app.buttons[Self.rowID].appears(timeout: Self.timeout))
        XCTAssertFalse(retry.exists)
        XCTAssertEqual(try requests(directory).filter { $0 == "scriptMonitor.list" }.count, 2)
        capture(app, "script-monitors-retried")
    }

    @MainActor
    func testUnsupportedConnectionDoesNotReadOrSubscribe() throws {
        let directory = try fixtureDirectory()
        let app = launch(directory: directory, scenario: "unsupported")
        XCTAssertTrue(app.textViews["composer.textView"].appears(timeout: Self.timeout))
        XCTAssertFalse(app.buttons[Self.rowID].exists)
        XCTAssertFalse(app.buttons["script-monitors-load-more"].exists)
        XCTAssertTrue(try requests(directory).isEmpty, "Unsupported negotiation must prevent both reads and subscriptions")
        capture(app, "script-monitors-unsupported")
    }

    @MainActor
    func testDeadlineRemainsVisibleUntilServerExpiry() throws {
        let directory = try fixtureDirectory()
        let app = launch(directory: directory, scenario: "deadline-reached")
        let row = app.buttons[Self.rowID]
        XCTAssertTrue(row.appears(timeout: Self.timeout))
        XCTAssertEqual((row.value as? String)?.contains("awaiting confirmation"), true)
        capture(app, "script-monitors-deadline")
        try trigger("expired", directory: directory)
        XCTAssertTrue(row.disappears(timeout: Self.timeout))
        capture(app, "script-monitors-expired")
    }

    @MainActor
    func testSeveralWatchesShareOneCountedPill() throws {
        let directory = try fixtureDirectory()
        let app = launch(directory: directory, scenario: "multiple")
        let pill = app.buttons["script-monitors-menu"]
        XCTAssertTrue(pill.appears(timeout: Self.timeout))
        XCTAssertTrue(pill.label.contains("Watching 3 scripts"), pill.label)
        XCTAssertFalse(app.buttons[Self.rowID].exists, "Several watches must not render one pill each")
        capture(app, "script-monitors-multiple")
        pill.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", Self.originalName)).firstMatch
        XCTAssertTrue(item.appears(timeout: Self.timeout))
        capture(app, "script-monitors-multiple-menu")
        item.tap()
        assertDetailText(app, "demo-run-watched-original")
        capture(app, "script-monitors-multiple-details")
        closeDetails(app)
    }

    @MainActor
    private func launch(
        directory: URL,
        scenario: String = "active",
        design: String = "conversation",
        accessibility: Bool = false,
        appearance: String = "light",
        longPrLabel: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication.intent()
        app.launchArguments = [
            "--demo-data", "--demo-design-scenario=" + design, "--demo-script-monitors=" + scenario,
            "--demo-script-monitor-hit-probe",
            "--demo-script-monitor-directory=" + directory.path, "-appThemePreference", accessibility ? "dark" : appearance
        ]
        if longPrLabel { app.launchArguments.append("--demo-long-pr-label") }
        if accessibility { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        addTeardownBlock { @MainActor [self] () async in
            if app.state == .runningForeground { capture(app, "script-monitors-final-state") }
            app.terminate()
        }
        let workspace = app.staticTexts["Workspace agent design"].firstMatch
        XCTAssertTrue(workspace.appears(timeout: Self.timeout))
        let agent = app.staticTexts["Continue Spec Writer"].firstMatch
        if !(agent.exists && agent.isHittable) { workspace.tap() }
        XCTAssertTrue(agent.appears(timeout: Self.timeout))
        agent.tap()
        return app
    }

    private func fixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("script-monitors-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func requests(_ directory: URL) throws -> [String] {
        try String(contentsOf: directory.appendingPathComponent("requests"), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private func trigger(_ action: String, directory: URL) throws {
        try Data().write(to: directory.appendingPathComponent(action), options: .atomic)
    }

    @MainActor
    private func assertDetailText(_ app: XCUIApplication, _ text: String) {
        let label = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(label.appears(timeout: Self.timeout), "Details must contain: " + text)
    }

    @MainActor
    private func closeDetails(_ app: XCUIApplication) {
        let close = app.buttons["connection-sheet.close"]
        XCTAssertTrue(close.appears(timeout: Self.timeout))
        close.tap()
        XCTAssertTrue(close.disappears(timeout: Self.timeout))
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

extension ScriptMonitorsUITests {
}
