import XCTest

/// Run on both iPhone (compact) and iPad (regular) when validation resumes.
/// Uses demo data, never a live backend or an automatic share destination.
nonisolated final class DiagnosticExportUITests: XCTestCase {
    private static let timeout: TimeInterval = 15
    private static let maximumSwipes = 6

    @MainActor
    func testWorkspaceMenuOrderPreviewClearCancelAndReopen() {
        let app = launch()
        openMenu(app)
        let settings = app.buttons["Settings"]
        let connect = app.buttons["Connect to…"]
        let export = app.buttons["Export logs"]
        XCTAssertTrue(settings.exists)
        XCTAssertTrue(connect.exists)
        XCTAssertTrue(export.waitForExistence(timeout: Self.timeout))
        XCTAssertLessThan(settings.frame.midY, connect.frame.midY)
        XCTAssertLessThan(connect.frame.midY, export.frame.midY)
        let create = app.buttons["Create New Workspace"]
        if create.exists { XCTAssertLessThan(create.frame.midY, settings.frame.midY) }
        export.tap()
        assertPreview(app)
        let retainedRecords = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", " retained records")).firstMatch
        let originalCount = retainedRecords.label
        XCTAssertNotEqual(originalCount, "0 retained records")
        let sessionStarted = app.staticTexts["app.session_started"].firstMatch
        XCTAssertTrue(sessionStarted.exists)

        // Opening the entry presents our readable screen, not UIKit sharing.
        app.buttons["diagnosticClear"].tap()
        XCTAssertTrue(app.buttons["Clear logs"].waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(app.staticTexts["Clear local diagnostic logs?"].exists)
        let oldMessage = NSPredicate(format: "label CONTAINS %@", "This removes local diagnostic history")
        XCTAssertFalse(app.staticTexts.matching(oldMessage).firstMatch.exists)
        cancelClear(in: app)
        assertPreview(app)
        XCTAssertEqual(retainedRecords.label, originalCount, "Cancelling must preserve the reviewed history")
        XCTAssertFalse(app.staticTexts["diagnosticNotice"].exists)
        app.navigationBars["Export logs"].buttons["Done"].tap()
        openMenu(app)
        app.buttons["Export logs"].tap()
        assertPreview(app)
        XCTAssertTrue(sessionStarted.exists, "Reopening must still read the retained session history")
        app.buttons["diagnosticClear"].tap()
        XCTAssertTrue(app.buttons["Clear logs"].waitForExistence(timeout: Self.timeout))
        app.buttons["Clear logs"].tap()
        XCTAssertTrue(app.staticTexts["diagnosticNotice"].waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(app.staticTexts["diagnosticNotice"].label, "Local log history cleared. New events can still be recorded.")
        XCTAssertTrue(sessionStarted.waitForNonExistence(timeout: Self.timeout), "Confirmed Clear must remove prior history")
    }

    @MainActor
    func testSettingsEntryAndLargeTextKeepExplicitActionsAccessible() {
        let app = launch(largeText: true)
        openMenu(app)
        app.buttons["Settings"].tap()
        let export = app.buttons["Export logs"]
        for _ in 0..<Self.maximumSwipes where !export.isHittable { app.swipeUp() }
        XCTAssertTrue(export.isHittable)
        export.tap()
        assertPreview(app)
        XCTAssertTrue(app.buttons["diagnosticShareZIP"].isHittable)
        XCTAssertTrue(app.buttons["diagnosticClear"].isHittable)
    }

    @MainActor
    private func launch(largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]
        }
        app.launch()
        return app
    }

    @MainActor
    private func openMenu(_ app: XCUIApplication) {
        let options = app.buttons["Workspace options"]
        XCTAssertTrue(options.waitForExistence(timeout: Self.timeout))
        options.tap()
    }

    @MainActor
    private func cancelClear(in app: XCUIApplication) {
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        } else {
            // Native confirmation popovers expose their outside-dismiss region,
            // including on iPhone under iOS 26, instead of a Cancel button.
            let dismissRegion = app.otherElements["PopoverDismissRegion"]
            XCTAssertTrue(dismissRegion.waitForExistence(timeout: Self.timeout))
            XCTAssertTrue(dismissRegion.isHittable)
            dismissRegion.tap()
        }
        XCTAssertTrue(app.buttons["Clear logs"].waitForNonExistence(timeout: Self.timeout))
    }

    @MainActor
    private func assertPreview(_ app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Export logs"].waitForExistence(timeout: Self.timeout))
        let share = app.buttons["diagnosticShareZIP"]
        XCTAssertTrue(share.waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(share.label, "Share ZIP")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: share)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: Self.timeout), .completed)
        XCTAssertTrue(app.buttons["diagnosticClear"].exists)
        XCTAssertTrue(app.buttons["Refresh"].exists)
        XCTAssertTrue(app.navigationBars["Export logs"].buttons["Done"].exists)
        XCTAssertTrue(app.buttons["Metadata and coverage"].exists)
        let removedSection = NSPredicate(format: "label ==[c] %@", "About these logs")
        XCTAssertFalse(app.staticTexts.matching(removedSection).firstMatch.exists)
    }
}
