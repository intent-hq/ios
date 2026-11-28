import XCTest

private typealias LossFixture = ConnectionLossUITestFixture

extension ConnectionLossUITests {
    @MainActor
    func testStopAndQueuedMessagesAreReadOnlyDuringDrop() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "Workspace phone presentation")
        let directory = try makeTriggerDirectory()
        let app = launch(directory: directory, arguments: [
            "--demo-connection-loss-reconnecting", "--demo-design-scenario=queue"
        ])
        openDesignConversation(in: app)
        let stop = app.buttons["Stop response"].firstMatch
        XCTAssertTrue(stop.appears(timeout: LossFixture.timeout))
        let sendNow = app.buttons["Send queued message now"].firstMatch
        XCTAssertTrue(sendNow.appears(timeout: LossFixture.timeout))
        try trigger("loss", in: directory)
        assertBanner(in: app)
        XCTAssertFalse(stop.isEnabled, "Stop")
        for label in ["Send queued message now", "Edit queued message", "Remove queued message"] {
            XCTAssertFalse(app.buttons[label].firstMatch.isEnabled, label)
        }
        capture(app, named: "read-only-queue")
        try trigger("recover", in: directory)
        XCTAssertTrue(app.buttons[LossFixture.bannerIdentifier].disappears(timeout: LossFixture.timeout))
        let live = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: sendNow)
        XCTAssertEqual(XCTWaiter.wait(for: [live], timeout: LossFixture.timeout), .completed)
    }

    // MARK: - Helpers

    @MainActor @discardableResult
    func assertBanner(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let banner = app.buttons[LossFixture.bannerIdentifier]
        XCTAssertTrue(banner.appears(timeout: LossFixture.timeout), file: file, line: line)
        XCTAssertTrue(banner.isHittable, file: file, line: line)
        XCTAssertTrue(banner.label.contains("Read-only"), "Banner says read-only: \(banner.label)", file: file, line: line)
        XCTAssertFalse(app.buttons[LossFixture.homeIdentifier].exists, "No blocking screen while reconnecting", file: file, line: line)
        return banner
    }

    @MainActor
    func assertStoppedTitle(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let title = app.staticTexts.matching(NSPredicate(
            format: "identifier == %@ AND label MATCHES %@", "connection-loss.status", "Can’t reconnect( to Demo Mac)?"
        )).firstMatch
        XCTAssertTrue(title.appears(timeout: LossFixture.timeout), file: file, line: line)
    }

    @MainActor
    func assertBannerTitle(_ title: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let banner = app.buttons.matching(NSPredicate(
            format: "identifier == %@ AND label MATCHES %@", LossFixture.bannerIdentifier, title
        )).firstMatch
        XCTAssertTrue(banner.appears(timeout: LossFixture.timeout), "Banner title: \(title)", file: file, line: line)
    }

    @MainActor
    func tap(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.appears(timeout: LossFixture.timeout), app.debugDescription, file: file, line: line)
        element.tap()
    }

    @MainActor
    private func openDesignConversation(in app: XCUIApplication) {
        tap(app.staticTexts["Workspace agent design"].firstMatch, in: app)
        tap(app.staticTexts["Continue Spec Writer"].firstMatch, in: app)
    }
}
