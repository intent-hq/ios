import XCTest

nonisolated final class TranscriptVideoUITests: XCTestCase {
    private let timeout: TimeInterval = 15
    private let launchTimeout: TimeInterval = 30

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        continueAfterFailure = true
        try super.tearDownWithError()
    }

    @MainActor
    func testSentVideoPosterOpensFullScreenPlayback() {
        let app = XCUIApplication.intent()
        app.launchArguments += ["--demo-data", "--demo-transcript-video"]
        app.launch()
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        if !workspace.appears(timeout: launchTimeout) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(workspace.appears(timeout: timeout))
        }
        workspace.tap()
        let agent = app.staticTexts["Dashboard Implementor"].firstMatch
        XCTAssertTrue(agent.appears(timeout: timeout))
        agent.tap()

        let poster = app.buttons["Video: Recording.mp4"].firstMatch
        XCTAssertTrue(poster.appears(timeout: timeout), "A sent video must render as a playable poster")
        let transcript = app.scrollViews["transcript.scrollView"]
        XCTAssertTrue(waitUntil(timeout: timeout) { poster.isHittable && isInside(poster, transcript) })
        XCTAssertNotNil(waitUntilSteady(timeout: timeout, tolerance: 1) { poster.frame.midY })
        poster.tap()

        let close = app.buttons["Close video"].firstMatch
        XCTAssertTrue(close.appears(timeout: timeout), "Tapping the poster must open full-screen playback")
        XCTAssertTrue(waitUntil(timeout: timeout) { close.isHittable })
        XCTAssertFalse(app.alerts["Could not start video playback"].exists)
        capture(app, named: "Sent video full-screen playback")
        close.tap()
        XCTAssertTrue(close.disappears(timeout: timeout))
        XCTAssertTrue(poster.appears(timeout: timeout))
        XCTAssertTrue(
            waitUntil(timeout: timeout) { poster.isHittable },
            "Closing playback must return to the transcript poster"
        )
        capture(app, named: "Sent video poster")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
