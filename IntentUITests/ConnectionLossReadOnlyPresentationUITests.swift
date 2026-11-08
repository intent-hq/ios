import XCTest

private typealias LossFixture = ConnectionLossUITestFixture

/// The banner reserves safe area for everything the window presents, and its
/// separate window never takes the keyboard from the app.
extension ConnectionLossUITests {
    @MainActor
    func testCoversAndSheetsStayBelowTheBannerDuringDrop() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "Walks the phone navigation stack")
        let directory = try makeTriggerDirectory()
        let app = launch(directory: directory, arguments: ["--demo-connection-loss-reconnecting"])
        try trigger("loss", in: directory)
        let banner = assertBanner(in: app)

        tap(app.staticTexts[LossFixture.workspaceTitle].firstMatch, in: app)
        tap(app.buttons["Context"].firstMatch, in: app)
        let file = app.buttons["files.file.README.md"].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: LossFixture.timeout) || app.scrollViews.firstMatch.exists)
        for _ in 0..<LossFixture.scrollAttempts where !file.isHittable { app.swipeUp() }
        tap(file, in: app)
        // Text files preview with a Back button; other types use "Close file".
        let close = app.buttons["text.close"]
        XCTAssertTrue(close.waitForExistence(timeout: LossFixture.timeout), "The full-screen file preview opens during a drop")
        assertBelowBanner(close, banner: banner, "Back from the file preview")
        capture(app, named: "read-only-cover-close")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: LossFixture.timeout), "The preview closes under the banner")

        returnToWorkspaceList(in: app)
        app.openHomeAction("settings")
        let settingsClose = app.buttons["settings.close"]
        XCTAssertTrue(settingsClose.waitForExistence(timeout: LossFixture.timeout))
        assertBelowBanner(settingsClose, banner: banner, "Close settings")
        capture(app, named: "read-only-sheet-close")
        settingsClose.tap()
        XCTAssertTrue(settingsClose.waitForNonExistence(timeout: LossFixture.timeout), "Settings closes under the banner")
        XCTAssertTrue(banner.exists, "The banner stays through every presentation")
    }

    @MainActor
    func testTappingTheBannerKeepsTheComposerKeyboardUp() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "Phone composer")
        let directory = try makeTriggerDirectory()
        let app = launch(directory: directory, arguments: ["--demo-connection-loss-reconnecting"])
        openConversation(in: app)
        let composer = app.textViews["composer.textView"]
        XCTAssertTrue(composer.waitForExistence(timeout: LossFixture.timeout))
        try trigger("loss", in: directory)
        let banner = assertBanner(in: app)
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: LossFixture.timeout))
        composer.typeText("Before ")
        banner.tap()
        XCTAssertTrue(app.buttons[LossFixture.bannerHomeIdentifier].waitForExistence(timeout: LossFixture.timeout), "The banner expanded")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Tapping the banner must not dismiss the keyboard")
        composer.typeText("after")
        XCTAssertEqual(composer.value as? String, "Before after", "The composer kept focus")
    }

    @MainActor
    func testIPadControlInventoryDuringDrop() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad rail and Assistant sidebar")
        let directory = try makeTriggerDirectory()
        let app = launch(directory: directory, arguments: ["--demo-connection-loss-reconnecting"])
        try trigger("loss", in: directory)
        assertBanner(in: app)
        XCTAssertFalse(app.buttons["ipad.rail.createWorkspace"].isEnabled, "New workspace needs the Mac")
        for section in ["assistant", "workspaces", "pullRequests", "connections", "settings"] {
            XCTAssertTrue(app.buttons["ipad.rail.\(section)"].isEnabled, "Navigation stays on: \(section) (R1.13)")
        }
        XCTAssertTrue(app.buttons["ipad.rail.appearance"].isEnabled, "Appearance is local")
        app.buttons["ipad.rail.assistant"].tap()
        let create = app.buttons["assistant.sidebar.newConversation"]
        XCTAssertTrue(create.waitForExistence(timeout: LossFixture.timeout), "The Assistant opens from the last confirmed owner")
        XCTAssertFalse(create.isEnabled, "A new Assistant conversation needs the Mac")
        capture(app, named: "ipad-read-only-assistant")
    }

    @MainActor
    private func assertBelowBanner(
        _ element: XCUIElement,
        banner: XCUIElement,
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.isHittable, "\(name) must be tappable", file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            element.frame.minY,
            banner.frame.maxY + LossFixture.bannerPadding - LossFixture.layoutTolerance,
            "The banner must not cover \(name)",
            file: file,
            line: line
        )
    }
}
