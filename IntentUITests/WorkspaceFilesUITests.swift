import XCTest

nonisolated final class WorkspaceFilesUITests: XCTestCase {
    private enum Fixture {
        static let timeout: TimeInterval = 30
        static let scrollAttempts = 6
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
    func testBrowseFilesAndPreserveFoldersAcrossTabsInBothThemes() {
        for appearance in ["light", "dark"] {
            let app = openContext(appearance: appearance)
            let notes = app.buttons["context.section.notes"].firstMatch
            reveal(notes, in: app)
            XCTAssertTrue(app.buttons["workspace.note.demo-note-spec"].exists)
            capture(app, name: "workspace-context-\(appearance)")
            notes.tap()
            let sources = app.buttons["files.folder.Sources"].firstMatch
            reveal(sources, in: app)
            sources.tap()
            let analytics = app.buttons["files.folder.Sources/Analytics"].firstMatch
            reveal(analytics, in: app)
            analytics.tap()
            let file = app.buttons["files.file.Sources/Analytics/Events.swift"].firstMatch
            reveal(file, in: app)
            capture(app, name: "workspace-files-\(appearance)")
            file.tap()
            let text = app.textViews["text.content"].firstMatch
            XCTAssertTrue(text.waitForExistence(timeout: Fixture.timeout))
            XCTAssertEqual((text.value as? String)?.contains("case workspaceOpened"), true)
            capture(app, name: "workspace-file-preview-\(appearance)")
            app.buttons["text.close"].tap()
            reveal(analytics, in: app)
            analytics.tap()
            XCTAssertFalse(file.exists)
            sources.tap()
            sources.tap()
            XCTAssertEqual(analytics.value as? String, "Collapsed")
            let changes = app.buttons["Changes"].firstMatch
            reveal(changes, in: app, towardTop: true)
            changes.tap()
            let context = app.buttons["Context"].firstMatch
            reveal(context, in: app, towardTop: true)
            context.tap()
            reveal(analytics, in: app)
            XCTAssertEqual(analytics.value as? String, "Collapsed")
            XCTAssertEqual(notes.value as? String, "Collapsed")
            analytics.tap()
            reveal(file, in: app)
            app.terminate()
        }
    }

    @MainActor
    func testEmptyFolderAndIndependentContextSections() {
        let app = openContext(appearance: "light")
        let notes = app.buttons["context.section.notes"].firstMatch
        reveal(notes, in: app)
        notes.tap()
        let docs = app.buttons["files.folder.docs"].firstMatch
        reveal(docs, in: app)
        docs.tap()
        XCTAssertTrue(app.staticTexts["Empty folder"].waitForExistence(timeout: Fixture.timeout))
        let files = app.buttons["context.section.files"].firstMatch
        files.tap()
        XCTAssertFalse(docs.exists)
        notes.tap()
        XCTAssertTrue(app.buttons["workspace.note.demo-note-spec"].exists)
        XCTAssertEqual(files.value as? String, "Collapsed")
        notes.tap()
        files.tap()
        XCTAssertEqual(docs.value as? String, "Expanded")
        XCTAssertTrue(app.staticTexts["Empty folder"].exists)
    }

    @MainActor
    private func openContext(appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "-appThemePreference", appearance]
        app.launch()
        let workspace = app.buttons["workspace.row.demo-ws-dashboard"]
        XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.timeout))
        workspace.tap()
        let context = app.buttons["Context"].firstMatch
        XCTAssertTrue(context.waitForExistence(timeout: Fixture.timeout))
        context.tap()
        return app
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
        for _ in 0..<Fixture.scrollAttempts {
            if element.exists, element.isHittable { return }
            if towardTop { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(element.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
