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
    func testEmptyFolderAndIndependentContextSections() {
        let app = openContext(appearance: "light")
        let notes = app.buttons["context.section.notes"].firstMatch
        reveal(notes, in: app)
        notes.tap()
        let docs = app.buttons["files.folder.docs"].firstMatch
        reveal(docs, in: app)
        docs.tap()
        XCTAssertTrue(app.staticTexts["Empty folder"].appears(timeout: Fixture.timeout))
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
    func testTypeScriptFileOpensInTextViewerNotVideoPreview() {
        let app = openContext(appearance: "light")
        let notes = app.buttons["context.section.notes"].firstMatch
        reveal(notes, in: app)
        notes.tap()
        let web = app.buttons["files.folder.Web"].firstMatch
        reveal(web, in: app)
        web.tap()
        let file = app.buttons["files.file.Web/collector.ts"].firstMatch
        reveal(file, in: app)
        file.tap()
        let text = app.textViews["text.content"].firstMatch
        XCTAssertTrue(text.appears(timeout: Fixture.timeout))
        XCTAssertEqual((text.value as? String)?.contains("export function collect"), true)
        XCTAssertTrue(app.buttons["text.close"].exists)
        XCTAssertFalse(app.staticTexts["Loading file…"].exists)
        XCTAssertFalse(app.staticTexts["File unavailable"].exists)
        XCTAssertFalse(app.buttons["Close video"].exists)
    }

    @MainActor
    private func openContext(appearance: String) -> XCUIApplication {
        let app = XCUIApplication.intent()
        app.launchArguments = ["--demo-data", "-appThemePreference", appearance]
        app.launch()
        let workspace = app.buttons["workspace.row.demo-ws-dashboard"]
        XCTAssertTrue(workspace.appears(timeout: Fixture.timeout))
        workspace.tap()
        let context = app.buttons["Context"].firstMatch
        XCTAssertTrue(context.appears(timeout: Fixture.timeout))
        context.tap()
        return app
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
        for _ in 0..<Fixture.scrollAttempts {
            if element.exists, element.isHittable { return }
            if towardTop { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(element.appears(timeout: Fixture.timeout))
        XCTAssertTrue(element.isHittable)
    }
}
