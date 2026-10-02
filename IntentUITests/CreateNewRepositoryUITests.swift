import XCTest

nonisolated final class CreateNewRepositoryUITests: XCTestCase {
    private static let elementTimeout: TimeInterval = 15

    @MainActor
    func testNewRepositoryWithoutGitHubPreservesDraftAndRetriesCreation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "--demo-github-disconnected"]
        app.launch()
        app.openHomeAction("workspace")
        XCTAssertTrue(app.staticTexts["GitHub Is Not Connected"].waitForExistence(timeout: Self.elementTimeout))
        app.buttons["creation.newRepository"].tap()
        let name = app.textFields["creation.newRepositoryName"]
        XCTAssertTrue(name.waitForExistence(timeout: Self.elementTimeout))
        XCTAssertFalse(app.buttons["Next"].isEnabled)
        name.tap()
        name.typeText("my-project")
        app.buttons["Next"].tap()
        let prompt = app.textViews["creation.prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: Self.elementTimeout))
        XCTAssertFalse(app.staticTexts["creation.branchTitle"].exists)
        let source = app.buttons["creation.sourceCard"]
        XCTAssertEqual(source.label, "Source. New repository: ~/Developer/my-project")
        prompt.tap()
        prompt.typeText("Build my new project")
        XCTAssertTrue(app.buttons["creation.create"].isHittable)
        attachEvidence(in: app, name: "new-repository-create-with-keyboard")
        app.revealWorkspaceSource().tap()
        XCTAssertTrue(name.waitForExistence(timeout: Self.elementTimeout))
        XCTAssertEqual(name.value as? String, "my-project")
        app.buttons["Next"].tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: Self.elementTimeout))
        XCTAssertEqual(prompt.value as? String, "Build my new project")
        let create = app.buttons["Create"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: create)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: Self.elementTimeout), .completed)
        create.tap()
        XCTAssertTrue(app.alerts["Error"].waitForExistence(timeout: Self.elementTimeout))
        app.alerts.buttons["OK"].tap()
        retryAfterSourceRevisit(in: app)
    }

    @MainActor
    private func retryAfterSourceRevisit(in app: XCUIApplication) {
        app.buttons["creation.sourceCard"].tap()
        let name = app.textFields["creation.newRepositoryName"]
        XCTAssertTrue(name.waitForExistence(timeout: Self.elementTimeout))
        app.buttons["creation.branchBack"].tap()
        app.buttons["creation.newRepository"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: Self.elementTimeout))
        app.buttons["Next"].tap()
        let prompt = app.textViews["creation.prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: Self.elementTimeout))
        XCTAssertEqual(prompt.value as? String, "Build my new project")
        XCTAssertEqual(app.buttons["creation.sourceCard"].label, "Source. New repository: ~/Developer/my-project")
        attachEvidence(in: app, name: "new-repository-draft-after-retry")
        app.buttons["Create"].tap()
        XCTAssertTrue(app.buttons["creation.sourceCard"].waitForNonExistence(timeout: Self.elementTimeout))
        XCTAssertFalse(app.alerts["Error"].exists)
    }

    @MainActor
    func testInvalidAndExistingDestinationsCannotAdvanceAndGitHubSelectionStillWorks() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data"]
        app.launch()
        app.openHomeAction("workspace")
        let repository = app.buttons["creation.repository.nova-labs/console"]
        XCTAssertTrue(repository.waitForExistence(timeout: Self.elementTimeout))
        repository.tap()
        app.buttons["creation.newRepository"].tap()
        let name = app.textFields["creation.newRepositoryName"]
        XCTAssertTrue(name.waitForExistence(timeout: Self.elementTimeout))
        name.tap()
        name.typeText("../project")
        XCTAssertFalse(app.buttons["Next"].isEnabled)
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "../project".count))
        name.typeText("existing-project")
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["creation.newRepositoryError"].waitForExistence(timeout: Self.elementTimeout))
        XCTAssertFalse(app.textViews["creation.prompt"].exists)
        attachEvidence(in: app, name: "existing-repository-destination-rejected")
        app.buttons["creation.branchBack"].tap()
        XCTAssertTrue(repository.waitForExistence(timeout: Self.elementTimeout))
        XCTAssertTrue(repository.isSelected)
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["creation.branchTitle"].waitForExistence(timeout: Self.elementTimeout))
        let branch = app.buttons["creation.branch.main"]
        XCTAssertTrue(branch.waitForExistence(timeout: Self.elementTimeout))
        branch.tap()
        app.buttons["Next"].tap()
        let source = app.buttons["creation.sourceCard"]
        XCTAssertTrue(source.waitForExistence(timeout: Self.elementTimeout))
        XCTAssertEqual(source.label, "Source. Repository: nova-labs/console. Branch: main")
    }

    @MainActor
    private func attachEvidence(in app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

private enum WorkspaceCreationTestSupport {
    static let maximumSwipes = 3
    static let gestureInset: CGFloat = 24
    static let dragDuration: TimeInterval = 0.1
}

extension XCUIApplication {
    @MainActor
    func revealWorkspaceSource(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let form = scrollViews["creation.form"]
        let source = buttons["creation.sourceCard"]
        let origin = coordinate(withNormalizedOffset: .zero)
        for _ in 0..<WorkspaceCreationTestSupport.maximumSwipes {
            let inset = WorkspaceCreationTestSupport.gestureInset
            let bottom = min(form.frame.maxY, buttons["creation.create"].frame.minY - inset)
            let viewport = CGRect(x: form.frame.minX, y: form.frame.minY, width: form.frame.width, height: bottom - form.frame.minY)
            if viewport.contains(source.frame) { return source }
            let start = origin.withOffset(CGVector(dx: form.frame.minX + inset / 2, dy: bottom - inset))
            let end = origin.withOffset(CGVector(dx: form.frame.minX + inset / 2, dy: form.frame.minY + inset))
            start.press(forDuration: WorkspaceCreationTestSupport.dragDuration, thenDragTo: end)
        }
        XCTFail("Scrolling must reveal the source selector above the Create button.", file: file, line: line)
        return source
    }
}
