import XCTest

/// Guards the workspace status image (intent-hq/intent#3868) against the
/// `--demo-data` fixtures: exactly one fixture workspace carries a
/// `statusImageAssetId`, its list row has no status image, the workspace
/// detail header renders the image, and tapping it opens the fullscreen
/// lightbox at a readable size. Rows without an asset render no image.
///
/// Runs under the `Intent` scheme (`scripts/xcodebuild.sh test-ios`, CI).
nonisolated final class WorkspaceStatusImageUITests: XCTestCase {
    private enum Fixture {
        /// `DemoFixtures.statusImageWorkspaceId`'s title: a workspace with no
        /// agents, so its detail header is the only surface to check.
        static let workspaceTitle = "Dark mode for settings screens"
        static let statusImageLabel = "Workspace status image"
        static let detailIdentifier = "workspaceDetail.statusImage"
        static let lightboxLabel = "Image preview"
        static let lightboxCloseLabel = "Close image"
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        continueAfterFailure = true
        try super.tearDownWithError()
    }

    @MainActor
    func testStatusImageIsAbsentFromListAndOpensFullSizeFromDetail() {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data"]
        app.launch()

        let workspaceRow = app.staticTexts[Fixture.workspaceTitle].firstMatch
        if !workspaceRow.waitForExistence(timeout: 30) {
            // Same fallback as AppStoreScreenshotTests: a collapsed iPad
            // sidebar hides the workspace list behind the first nav button.
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(workspaceRow.waitForExistence(timeout: 15))
        }

        // Allow an asynchronous image fetch to finish before checking that
        // even a workspace carrying statusImageAssetId has no list thumbnail.
        let listImage = app.descendants(matching: .any)[Fixture.statusImageLabel].firstMatch
        XCTAssertFalse(
            listImage.waitForExistence(timeout: 3),
            "workspace list rows must not render status image thumbnails"
        )

        workspaceRow.tap()

        let detailImage = app.descendants(matching: .any)
            .matching(identifier: Fixture.detailIdentifier).firstMatch
        XCTAssertTrue(
            detailImage.waitForExistence(timeout: 15),
            "status image never appeared in the workspace detail header"
        )
        let inlineWidth = detailImage.frame.width
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "workspace-summary-and-image"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        detailImage.tap()

        // The lightbox renders the image scaled to fit the whole screen, so
        // it is at least as wide as the padded inline rendering.
        let lightbox = app.descendants(matching: .any)[Fixture.lightboxLabel].firstMatch
        XCTAssertTrue(lightbox.waitForExistence(timeout: 10), "tapping the status image did not open the lightbox")
        XCTAssertGreaterThanOrEqual(lightbox.frame.width, inlineWidth)

        app.buttons[Fixture.lightboxCloseLabel].firstMatch.tap()
        XCTAssertTrue(lightbox.waitForNonExistence(timeout: 10), "the lightbox did not close")
        XCTAssertTrue(detailImage.exists)
    }
}
