import XCTest

nonisolated final class CreateWorkspaceDraftUITests: XCTestCase {
    private enum Fixture {
        static let timeout: TimeInterval = 15
        static let dismissalTimeout: TimeInterval = 3
        static let dragDuration: TimeInterval = 0.1
        static let dragEnd: CGFloat = 0.9
        static let prompt = "Keep this workspace prompt\nIncluding this second line."
    }

    @MainActor
    func testDismissedPromptRestoresAndClearsAfterSuccessfulRetry() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "--demo-github-create-retry"]
        app.launch()
        openGitHubForm(in: app)
        typePrompt(in: app)
        dismissForm(in: app)
        assertRestoredPrompt(in: app)
        XCTAssertEqual(app.buttons["creation.sourceCard"].label, "Source. Repository: nova-labs/console. Branch: feature/docs")
        attachEvidence(in: app)

        app.buttons["creation.create"].tap()
        XCTAssertTrue(app.alerts["Error"].waitForExistence(timeout: Fixture.timeout))
        app.alerts.buttons["OK"].tap()
        dismissForm(in: app)
        assertRestoredPrompt(in: app)
        app.buttons["creation.create"].tap()
        XCTAssertTrue(app.scrollViews["creation.form"].waitForNonExistence(timeout: Fixture.timeout))
        let back = app.buttons["workspaceDetail.back"]
        XCTAssertTrue(back.waitForExistence(timeout: Fixture.timeout))
        back.tap()
        app.openHomeAction("workspace")
        XCTAssertTrue(app.staticTexts["creation.repositoryTitle"].waitForExistence(timeout: Fixture.timeout))
        XCTAssertFalse(app.textViews["creation.prompt"].exists)
    }

    @MainActor
    func testNewRepositoryDraftRestoresAndErasingPromptStartsFresh() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data"]
        app.launch()
        app.openHomeAction("workspace")
        app.buttons["creation.newRepository"].tap()
        let name = app.textFields["creation.newRepositoryName"]
        XCTAssertTrue(name.waitForExistence(timeout: Fixture.timeout))
        name.tap()
        name.typeText("draft-project")
        app.buttons["Next"].tap()
        typePrompt(in: app)
        dismissForm(in: app)
        assertRestoredPrompt(in: app)
        XCTAssertEqual(app.buttons["creation.sourceCard"].label, "Source. New repository: ~/Developer/draft-project")

        let prompt = app.textViews["creation.prompt"]
        prompt.tap()
        prompt.press(forDuration: 1)
        let selectAll = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Select All")).firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: Fixture.timeout))
        selectAll.tap()
        prompt.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(prompt.value as? String, "")
        dismissForm(in: app)
        app.openHomeAction("workspace")
        XCTAssertTrue(app.staticTexts["creation.repositoryTitle"].waitForExistence(timeout: Fixture.timeout))
        XCTAssertFalse(prompt.exists)
    }

    @MainActor
    private func openGitHubForm(in app: XCUIApplication) {
        app.openHomeAction("workspace")
        let repo = app.buttons["creation.repository.nova-labs/console"]
        XCTAssertTrue(repo.waitForExistence(timeout: Fixture.timeout))
        repo.tap()
        app.buttons["Next"].tap()
        let branch = app.buttons["creation.branch.feature/docs"]
        XCTAssertTrue(branch.waitForExistence(timeout: Fixture.timeout))
        branch.tap()
        app.buttons["Next"].tap()
    }

    @MainActor
    private func typePrompt(in app: XCUIApplication) {
        let prompt = app.textViews["creation.prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: Fixture.timeout))
        prompt.tap()
        prompt.typeText(Fixture.prompt)
    }

    @MainActor
    private func dismissForm(in app: XCUIApplication) {
        let form = app.scrollViews["creation.form"]
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: Fixture.dragEnd))
        for _ in 0..<2 {
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: -1))
            start.press(forDuration: Fixture.dragDuration, thenDragTo: end)
            if form.waitForNonExistence(timeout: Fixture.dismissalTimeout) { break }
        }
        XCTAssertFalse(form.exists)
        XCTAssertTrue(app.buttons["intent.menu.open"].waitForExistence(timeout: Fixture.timeout))
    }

    @MainActor
    private func assertRestoredPrompt(in app: XCUIApplication) {
        app.openHomeAction("workspace")
        let prompt = app.textViews["creation.prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: Fixture.timeout))
        XCTAssertEqual(prompt.value as? String, Fixture.prompt)
        XCTAssertFalse(app.staticTexts["creation.repositoryTitle"].exists)
        let create = app.buttons["creation.create"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: create)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: Fixture.timeout), .completed)
    }

    @MainActor
    private func attachEvidence(in app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "restored-workspace-draft"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
