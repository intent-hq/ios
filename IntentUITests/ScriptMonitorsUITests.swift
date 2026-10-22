import UIKit
import XCTest

/// Run this same suite on iPhone and iPad. All data is synthetic; events enter
/// the normal connection/store path while the app remains running.
nonisolated final class ScriptMonitorsUITests: XCTestCase {
    private static let timeout: TimeInterval = 15
    private static let rowID = "script-monitor-demo-script-watch-owned"
    private static let originalName = "Build verification — long script name with 日本語 and accessibility context"
    private static let updatedName = "Renamed verification — same watch and run"
    private static let tapHeight: CGFloat = 44
    private static let pillSpacing: CGFloat = 8

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
        XCTAssertTrue(row.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(row.label.contains(Self.originalName), "VoiceOver must retain the full untruncated name")
        XCTAssertEqual((row.value as? String)?.contains("Watch expires"), true)
        XCTAssertFalse(app.buttons["script-monitor-demo-script-watch-other-owner"].exists)
        XCTAssertEqual(try requests(directory).filter { $0 == "scriptMonitor.list" }.count, 1)
        XCTAssertFalse(try requests(directory).contains("scriptMonitor.get"), "Summary hydration must not fetch details")
        capture(app, "script-monitors-active")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["script-monitor-details"].firstMatch.waitForExistence(timeout: Self.timeout))
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
        XCTAssertTrue(row.waitForNonExistence(timeout: Self.timeout))
        XCTAssertFalse(app.buttons["script-monitor-demo-script-watch-other-owner"].exists)
        XCTAssertEqual(try requests(directory).filter { $0 == "scriptMonitor.list" }.count, 1, "Complete events must update locally")
        capture(app, "script-monitors-removed")
    }

    @MainActor
    func testLoadingFailureRetriesWithoutInventingAnEmptyState() throws {
        let directory = try fixtureDirectory()
        let app = launch(directory: directory, scenario: "retry")
        XCTAssertTrue(app.descendants(matching: .any)["script-monitors-loading"].firstMatch.waitForExistence(timeout: Self.timeout))
        XCTAssertFalse(app.buttons[Self.rowID].exists)
        capture(app, "script-monitors-loading")
        try trigger("list-ready", directory: directory)
        let retry = app.buttons["script-monitors-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: Self.timeout))
        capture(app, "script-monitors-error")
        retry.tap()
        XCTAssertTrue(app.buttons[Self.rowID].waitForExistence(timeout: Self.timeout))
        XCTAssertFalse(retry.exists)
        XCTAssertEqual(try requests(directory).filter { $0 == "scriptMonitor.list" }.count, 2)
        capture(app, "script-monitors-retried")
    }

    @MainActor
    func testEmptyOwnerCanLoadNextPageAndRetryItsFailure() throws {
        let directory = try fixtureDirectory()
        let app = launch(directory: directory, scenario: "page-retry")
        let loadMore = app.buttons["script-monitors-load-more"]
        XCTAssertTrue(loadMore.waitForExistence(timeout: Self.timeout))
        XCTAssertFalse(app.buttons[Self.rowID].exists)
        XCTAssertFalse(app.buttons["script-monitor-demo-script-watch-other-owner"].exists)
        XCTAssertEqual(try requests(directory).filter { $0 == "scriptMonitor.list" }.count, 1)
        capture(app, "script-monitors-empty-owner-more")
        print("Script watch native hit report: " + app.descendants(matching: .any)["script-monitors.geometry"].firstMatch.label)
        XCTAssertGreaterThanOrEqual(loadMore.frame.height, Self.tapHeight)
        XCTAssertTrue(loadMore.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout), app.debugDescription)
        loadMore.tap()
        let retry = app.buttons["script-monitors-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(try requests(directory).filter { $0 == "scriptMonitor.list" }.count, 2)
        capture(app, "script-monitors-page-error")
        retry.tap()
        XCTAssertTrue(app.buttons[Self.rowID].waitForExistence(timeout: Self.timeout))
        XCTAssertFalse(loadMore.exists)
        XCTAssertEqual(try requests(directory).filter { $0 == "scriptMonitor.list" }.count, 3)
        capture(app, "script-monitors-next-page")
    }

    @MainActor
    func testDetailFailureRetainsSummaryAndRetriesOnlySelectedWatch() throws {
        let directory = try fixtureDirectory()
        let app = launch(directory: directory, scenario: "detail-retry")
        let row = app.buttons[Self.rowID]
        XCTAssertTrue(row.waitForExistence(timeout: Self.timeout))
        row.tap()
        let retry = app.buttons["script-monitor-details-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: Self.timeout))
        assertDetailText(app, "demo-run-watched-original")
        capture(app, "script-monitors-detail-error")
        retry.tap()
        XCTAssertTrue(retry.waitForNonExistence(timeout: Self.timeout))
        XCTAssertEqual(try requests(directory).filter { $0 == "scriptMonitor.get" }.count, 2)
        XCTAssertEqual(try requests(directory).filter { $0 == "scriptMonitor.list" }.count, 1)
        capture(app, "script-monitors-detail-retried")
    }

    @MainActor
    func testUnsupportedConnectionDoesNotReadOrSubscribe() throws {
        let directory = try fixtureDirectory()
        let app = launch(directory: directory, scenario: "unsupported")
        XCTAssertTrue(app.textViews["composer.textView"].waitForExistence(timeout: Self.timeout))
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
        XCTAssertTrue(row.waitForExistence(timeout: Self.timeout))
        XCTAssertEqual((row.value as? String)?.contains("awaiting confirmation"), true)
        capture(app, "script-monitors-deadline")
        try trigger("expired", directory: directory)
        XCTAssertTrue(row.waitForNonExistence(timeout: Self.timeout))
        capture(app, "script-monitors-expired")
    }

    @MainActor
    func testSeveralWatchesShareOneCountedPill() throws {
        let directory = try fixtureDirectory()
        let app = launch(directory: directory, scenario: "multiple")
        let pill = app.buttons["script-monitors-menu"]
        XCTAssertTrue(pill.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(pill.label.contains("Watching 3 scripts"), pill.label)
        XCTAssertFalse(app.buttons[Self.rowID].exists, "Several watches must not render one pill each")
        capture(app, "script-monitors-multiple")
        // Native Menu wrappers can report non-hittable while physical touch opens them.
        pill.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", Self.originalName)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: Self.timeout))
        capture(app, "script-monitors-multiple-menu")
        item.tap()
        assertDetailText(app, "demo-run-watched-original")
        capture(app, "script-monitors-multiple-details")
        closeDetails(app)
    }

    @MainActor
    func testQuestionFlowKeepsWatchReachableWithAccessibilityText() throws {
        let directory = try fixtureDirectory()
        let app = launch(directory: directory, design: "questions", accessibility: true)
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let option = isPad ? app.buttons["Yes, confirmed"] : app.buttons["question.option.0"]
        if isPad {
            XCTAssertTrue(option.waitForExistence(timeout: Self.timeout))
        } else {
            XCTAssertTrue(app.buttons["question.answer"].waitForExistence(timeout: Self.timeout))
        }
        let row = app.buttons[Self.rowID]
        XCTAssertTrue(row.waitForExistence(timeout: Self.timeout))
        print("Script watch native hit report: " + app.descendants(matching: .any)["script-monitors.geometry"].firstMatch.label)
        XCTAssertTrue(row.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout), app.debugDescription)
        XCTAssertGreaterThanOrEqual(row.frame.height, Self.tapHeight)
        XCTAssertTrue(row.label.contains(Self.originalName))
        capture(app, "script-monitors-question-accessibility")
        row.tap()
        assertDetailText(app, "demo-run-watched-original")
        capture(app, "script-monitors-question-details")
        try auditScrollableDetails(app)
        closeDetails(app)
        if !isPad { app.buttons["question.answer"].tap() }
        XCTAssertTrue(option.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(option.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout), app.debugDescription)
        if isPad { XCTAssertEqual(option.value as? String, "Not selected") }
    }

    @MainActor
    private func auditScrollableDetails(_ app: XCUIApplication) throws {
        let details = app.scrollViews["script-monitor-details"]
        XCTAssertTrue(details.waitForExistence(timeout: Self.timeout))
        let patternStart = "^(build|test) completed: "
        let patternEnd = " [0-9]+$"
        var unseen: Set<String> = [
            Self.originalName, "Command", "Continue Spec Writer", "demo-script-build-check",
            "demo-run-watched-original", "Created", "Watch expires", patternStart, patternEnd,
            "Also notifies after 25 new output lines."
        ]
        let maximumPages = 20
        for _ in 0..<maximumPages {
            let scrollFrame = details.frame
            let toolbarBottom = app.buttons["connection-sheet.close"].frame.maxY
            let viewport = CGRect(
                x: scrollFrame.minX,
                y: max(scrollFrame.minY, toolbarBottom),
                width: scrollFrame.width,
                height: scrollFrame.maxY - max(scrollFrame.minY, toolbarBottom)
            )
            var clippedText: Set<String> = []
            for text in details.staticTexts.allElementsBoundByIndex {
                let frame = text.frame
                // The full pattern is taller than the sheet at AX XXXL. Its
                // beginning and end must each be reachable, not visible at once.
                if text.label.hasPrefix(patternStart), text.label.hasSuffix(patternEnd) {
                    if viewport.contains(CGPoint(x: frame.midX, y: frame.minY)) { unseen.remove(patternStart) }
                    if viewport.contains(CGPoint(x: frame.midX, y: frame.maxY)) { unseen.remove(patternEnd) }
                }
                if viewport.contains(text.frame) {
                    unseen.remove(text.label)
                } else {
                    clippedText.insert(text.label + String(describing: text.frame))
                }
            }
            let deferredText = clippedText
            capture(app, "script-monitors-question-details")
            try app.performAccessibilityAudit(for: [.contrast, .sufficientElementDescription, .trait]) { issue in
                guard let element = issue.element else { return false }
                // XCTest reports contrast for clipped ScrollView descendants against
                // the pixels behind the sheet. Audit them after scrolling into view.
                // Overlapping scroll steps and the required labels above prevent
                // treating inaccessible or never-visible metadata as a passing audit.
                if issue.auditType == .contrast, element.elementType == .staticText,
                   deferredText.contains(element.label + String(describing: element.frame)) {
                    print("Deferred clipped contrast audit: " + element.debugDescription)
                    return true
                }
                print("Script watch accessibility issue: " + element.debugDescription)
                return false
            }
            if unseen.isEmpty { return }
            let start = details.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            let end = details.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        XCTFail("Watch metadata never became visible: " + unseen.sorted().joined(separator: ", "))
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
        let app = XCUIApplication()
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
        XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
        let agent = app.staticTexts["Continue Spec Writer"].firstMatch
        // iPad restores the workspace detail with its sidebar hidden; that hidden
        // sidebar row is intentionally not hittable, so only open the workspace
        // when its agent list is not already on screen.
        if !(agent.exists && agent.isHittable) { workspace.tap() }
        XCTAssertTrue(agent.waitForExistence(timeout: Self.timeout))
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
        XCTAssertTrue(label.waitForExistence(timeout: Self.timeout), "Details must contain: " + text)
    }

    @MainActor
    private func closeDetails(_ app: XCUIApplication) {
        let close = app.buttons["connection-sheet.close"]
        XCTAssertTrue(close.waitForExistence(timeout: Self.timeout))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: Self.timeout))
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
    @MainActor
    func testStatusPillsShareWidthAndStaySingleLineInBothThemes() throws {
        for appearance in ["light", "dark"] {
            let directory = try fixtureDirectory()
            let app = launch(directory: directory, scenario: "retry", appearance: appearance, longPrLabel: true)
            let monitor = app.buttons["monitoredPr.demo-design-pr-56"]
            XCTAssertTrue(monitor.waitForExistence(timeout: Self.timeout))
            XCTAssertEqual(monitor.label, "Monitoring PR intent-hq/intentd: #56")
            try trigger("list-ready", directory: directory)
            let retry = app.buttons["script-monitors-retry"]
            XCTAssertTrue(retry.waitForExistence(timeout: Self.timeout))
            assertPillWidths(monitor, retry, in: app)
            capture(app, "status-pills-retry-" + appearance)
            retry.tap()
            let watch = app.buttons[Self.rowID]
            XCTAssertTrue(watch.waitForExistence(timeout: Self.timeout))
            XCTAssertTrue(retry.waitForNonExistence(timeout: Self.timeout))
            XCTAssertTrue(watch.label.contains(Self.originalName))
            assertPillWidths(monitor, watch, in: app)
            capture(app, "status-pills-watching-" + appearance)
            watch.tap()
            assertDetailText(app, Self.originalName)
            closeDetails(app)
            capture(app, "script-monitors-final-state")
            app.terminate()
        }
    }

    @MainActor
    private func assertPillWidths(_ first: XCUIElement, _ second: XCUIElement, in app: XCUIApplication) {
        let row = app.otherElements["workspace-status-pills"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: Self.timeout))
        let maximumWidth = (row.frame.width - Self.pillSpacing) / 2
        for pill in [first, second] {
            XCTAssertGreaterThan(pill.frame.width, 0)
            XCTAssertLessThanOrEqual(pill.frame.width, maximumWidth + 1)
            XCTAssertEqual(pill.frame.height, Self.tapHeight, accuracy: 1, "Pill labels must remain on one line")
            XCTAssertTrue(row.frame.contains(pill.frame), "Pills must fit inside their row")
        }
        XCTAssertEqual(first.frame.midY, second.frame.midY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(second.frame.minX - first.frame.maxX, Self.pillSpacing - 1)
    }
}
