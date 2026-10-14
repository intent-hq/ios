import XCTest

nonisolated final class CreateNewRepositoryUITests: XCTestCase {
    private static let elementTimeout: TimeInterval = 15

    @MainActor
    func testGitHubRetryPreservesRequestAfterReturningToProjectPicker() {
        verifyGitHubRetry(switchToNewRepository: false)
    }

    @MainActor
    func testGitHubRetryKeepsItsRequestSeparateFromANewRepositoryAttempt() {
        verifyGitHubRetry(switchToNewRepository: true)
    }

    @MainActor
    private func verifyGitHubRetry(switchToNewRepository: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "--demo-github-create-retry"]
        app.launch()
        app.openHomeAction("workspace")
        openGitHubForm(in: app)
        submitExpectingLostResponse(in: app)
        returnToProjectPicker(in: app)
        if switchToNewRepository {
            app.buttons["creation.newRepository"].tap()
            let name = app.textFields["creation.newRepositoryName"]
            XCTAssertTrue(name.waitForExistence(timeout: Self.elementTimeout))
            name.tap()
            name.typeText("other-project")
            app.buttons["Next"].tap()
            submitExpectingLostResponse(in: app)
            returnToProjectPicker(in: app)
        }
        openGitHubForm(in: app)
        app.buttons["creation.create"].tap()
        XCTAssertTrue(app.buttons["creation.sourceCard"].waitForNonExistence(timeout: Self.elementTimeout))
        XCTAssertFalse(app.alerts["Error"].exists)
    }

    @MainActor
    private func openGitHubForm(in app: XCUIApplication) {
        let repository = app.buttons["creation.repository.nova-labs/console"]
        XCTAssertTrue(repository.waitForExistence(timeout: Self.elementTimeout))
        repository.tap()
        app.buttons["Next"].tap()
        let branch = app.buttons["creation.branch.main"]
        XCTAssertTrue(branch.waitForExistence(timeout: Self.elementTimeout))
        branch.tap()
        app.buttons["Next"].tap()
        waitForCreate(in: app)
    }

    @MainActor
    private func submitExpectingLostResponse(in app: XCUIApplication) {
        waitForCreate(in: app)
        app.buttons["creation.create"].tap()
        XCTAssertTrue(app.alerts["Error"].waitForExistence(timeout: Self.elementTimeout))
        app.alerts.buttons["OK"].tap()
    }

    @MainActor
    private func waitForCreate(in app: XCUIApplication) {
        let create = app.buttons["creation.create"]
        XCTAssertTrue(create.waitForExistence(timeout: Self.elementTimeout))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: create)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: Self.elementTimeout), .completed)
    }

    @MainActor
    private func returnToProjectPicker(in app: XCUIApplication) {
        app.buttons["creation.back"].tap()
        app.buttons["creation.branchBack"].tap()
        XCTAssertTrue(app.staticTexts["creation.repositoryTitle"].waitForExistence(timeout: Self.elementTimeout))
    }

    @MainActor
    func testNewRepositoryWithoutGitHubPreservesDraftAndRetriesCreation() throws {
        continueAfterFailure = false
        let gate = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-create-\(UUID().uuidString).trigger")
        defer { try? FileManager.default.removeItem(at: gate) }
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "--demo-github-disconnected", "--demo-workspace-create-trigger-file=" + gate.path]
        app.launch()
        app.openHomeAction("workspace")
        XCTAssertTrue(app.staticTexts["GitHub Is Not Connected"].waitForExistence(timeout: Self.elementTimeout))
        app.buttons["creation.newRepository"].tap()
        let name = app.textFields["creation.newRepositoryName"]
        XCTAssertTrue(name.waitForExistence(timeout: Self.elementTimeout))
        XCTAssertFalse(app.buttons["Next"].isEnabled)
        name.tap()
        name.typeText("my-project")
        XCTAssertTrue(app.buttons["creation.branchBack"].isHittable)
        attachEvidence(in: app, name: "new-repository-name-with-keyboard")
        app.buttons["Next"].tap()
        let prompt = app.textViews["creation.prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: Self.elementTimeout))
        XCTAssertFalse(app.staticTexts["creation.branchTitle"].exists)
        let source = app.buttons["creation.sourceCard"]
        XCTAssertEqual(source.label, "Source. New repository: ~/Developer/my-project")
        prompt.tap()
        prompt.typeText("Build my new project")
        XCTAssertTrue(app.buttons["creation.back"].isHittable)
        XCTAssertTrue(app.buttons["creation.create"].isHittable)
        attachEvidence(in: app, name: "new-repository-create-with-keyboard")
        app.revealWorkspaceSource().tap()
        XCTAssertTrue(name.waitForExistence(timeout: Self.elementTimeout))
        XCTAssertEqual(name.value as? String, "my-project")
        app.buttons["Next"].tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: Self.elementTimeout))
        XCTAssertEqual(prompt.value as? String, "Build my new project")
        try verifyPendingCreationAndRecovery(in: app, gate: gate)
        retryAfterSourceRevisit(in: app)
    }

    @MainActor
    private func verifyPendingCreationAndRecovery(in app: XCUIApplication, gate: URL) throws {
        app.textViews["creation.prompt"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Self.elementTimeout))
        let create = app.buttons["creation.create"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: create)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: Self.elementTimeout), .completed)
        let keyboardVisibleButtonY = create.frame.minY
        create.tap()
        let loading = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Creating workspace'"), object: create)
        XCTAssertEqual(XCTWaiter.wait(for: [loading], timeout: Self.elementTimeout), .completed)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertGreaterThan(create.frame.minY, keyboardVisibleButtonY)
        XCTAssertFalse(create.isEnabled)
        XCTAssertFalse(app.buttons["creation.back"].isEnabled)
        XCTAssertFalse(app.buttons["creation.sourceCard"].isEnabled)
        XCTAssertEqual(app.textViews["creation.prompt"].value as? String, "Build my new project")
        attachEvidence(in: app, name: "new-repository-creating")
        try Data().write(to: gate)
        XCTAssertTrue(app.alerts["Error"].waitForExistence(timeout: Self.elementTimeout))
        app.alerts.buttons["OK"].tap()
        XCTAssertEqual(create.label, "Create")
        XCTAssertTrue(create.isEnabled)
        XCTAssertTrue(app.buttons["creation.back"].isEnabled)
        attachEvidence(in: app, name: "new-repository-create-recovered")
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
            let bottom = min(form.frame.maxY, buttons["creation.create"].frame.minY)
            let viewport = CGRect(x: form.frame.minX, y: form.frame.minY, width: form.frame.width, height: bottom - form.frame.minY)
            let tapPoint = CGPoint(x: source.frame.midX, y: source.frame.midY)
            if source.isHittable, viewport.contains(tapPoint) { return source }
            let gutterX = form.frame.minX + inset / 2
            let start = origin.withOffset(CGVector(dx: gutterX, dy: bottom - inset))
            let end = origin.withOffset(CGVector(dx: gutterX, dy: form.frame.minY + inset))
            start.press(forDuration: WorkspaceCreationTestSupport.dragDuration, thenDragTo: end)
        }
        XCTFail("Scrolling must reveal the source selector above the Create button.", file: file, line: line)
        return source
    }
}
