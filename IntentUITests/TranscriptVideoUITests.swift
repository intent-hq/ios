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
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-transcript-video"]
        app.launch()
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        if !workspace.waitForExistence(timeout: launchTimeout) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(workspace.waitForExistence(timeout: timeout))
        }
        workspace.tap()
        let agent = app.staticTexts["Dashboard Implementor"].firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: timeout))
        agent.tap()

        let poster = app.buttons["Video: Recording.mp4"].firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: timeout), "A sent video must render as a playable poster")
        let transcript = app.scrollViews["transcript.scrollView"]
        XCTAssertTrue(waitUntil(timeout: timeout) { poster.isHittable && isInside(poster, transcript) })
        XCTAssertNotNil(waitUntilSteady(timeout: timeout, tolerance: 1) { poster.frame.midY })
        poster.tap()

        let close = app.buttons["Close video"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: timeout), "Tapping the poster must open full-screen playback")
        XCTAssertTrue(waitUntil(timeout: timeout) { close.isHittable })
        XCTAssertFalse(app.alerts["Could not start video playback"].exists)
        capture(app, named: "Sent video full-screen playback")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: timeout))
        XCTAssertTrue(poster.waitForExistence(timeout: timeout))
        XCTAssertTrue(
            waitUntil(timeout: timeout) { poster.isHittable },
            "Closing playback must return to the transcript poster"
        )
        capture(app, named: "Sent video poster")
    }

    @MainActor
    func testSentVideoOffersCopyAndShare() {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-transcript-video"]
        app.launch()
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        if !workspace.waitForExistence(timeout: launchTimeout) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(workspace.waitForExistence(timeout: timeout))
        }
        workspace.tap()
        let agent = app.staticTexts["Dashboard Implementor"].firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: timeout))
        agent.tap()

        let poster = app.buttons["Video: Recording.mp4"].firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: timeout))
        let transcript = app.scrollViews["transcript.scrollView"]
        XCTAssertTrue(waitUntil(timeout: timeout) { poster.isHittable && isInside(poster, transcript) })
        XCTAssertNotNil(waitUntilSteady(timeout: timeout, tolerance: 1) { poster.frame.midY })
        poster.press(forDuration: 1)

        let copy = app.buttons["Copy Video"].firstMatch
        let share = app.buttons["Share Video"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: timeout), "Long-pressing a video must offer Copy Video")
        XCTAssertTrue(share.waitForExistence(timeout: timeout), "Long-pressing a video must offer Share Video")
        capture(app, named: "Sent video copy and share menu")
        share.tap()

        let shareSheet = app.otherElements["ActivityListView"].firstMatch
        XCTAssertTrue(shareSheet.waitForExistence(timeout: timeout), "Share Video must open the system share sheet")
        capture(app, named: "Sent video share sheet")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        XCTAssertTrue(shareSheet.waitForNonExistence(timeout: timeout))

        XCTAssertTrue(waitUntil(timeout: timeout) { poster.isHittable })
        poster.tap()
        let playerShare = app.buttons["Share video"].firstMatch
        XCTAssertTrue(playerShare.waitForExistence(timeout: timeout), "Full-screen playback must offer Share")
        XCTAssertTrue(waitUntil(timeout: timeout) { playerShare.isHittable })
        capture(app, named: "Sent video full-screen share button")
        app.buttons["Close video"].firstMatch.tap()
    }

    @MainActor
    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
