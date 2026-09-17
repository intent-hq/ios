import XCTest

/// Guards the workspace status image (intent-hq/intent#3868) against the
/// `--demo-data` fixtures: exactly one fixture workspace carries a
/// `statusImageAssetId`, its list row renders the thumbnail, the workspace
/// detail header renders the image, and tapping it opens the fullscreen
/// lightbox at a readable size. Rows without an asset render no image.
///
/// Runs under the `Intent` scheme (`scripts/xcodebuild.sh test-ios`, CI).
nonisolated final class WorkspaceStatusImageUITests: XCTestCase {
    private enum Fixture {
        /// `DemoFixtures.statusImageWorkspaceId`'s title: a workspace with no agents.
        static let workspaceTitle = "Dark mode for settings screens"
        static let cardIdentifier = "workspaceRow.statusImage"
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
    func testStatusImageRendersOnTheCardAndOpensFullSizeFromDetail() {
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

        // The card thumbnail is fetched over the fixture `note.readAsset`
        // after the list renders, so wait for it rather than asserting once.
        let cardImages = app.descendants(matching: .any).matching(identifier: Fixture.cardIdentifier)
        XCTAssertTrue(
            cardImages.firstMatch.waitForExistence(timeout: 15),
            "status image thumbnail never appeared on the fixture workspace row"
        )
        XCTAssertEqual(
            cardImages.count,
            1,
            "only the fixture workspace carrying statusImageAssetId may render a thumbnail"
        )

        workspaceRow.tap()

        let detailImage = app.descendants(matching: .any)
            .matching(identifier: Fixture.detailIdentifier).firstMatch
        XCTAssertTrue(
            detailImage.waitForExistence(timeout: 15),
            "status image never appeared in the workspace detail header"
        )
        let inlineWidth = detailImage.frame.width
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
