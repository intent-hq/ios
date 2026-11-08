import UIKit
import XCTest

nonisolated final class QuestionAttachmentUITests: XCTestCase {
    private static let timeout: TimeInterval = 15

    @MainActor
    func testImageAnswerCanBeRemovedReattachedAndSentAcrossSteps() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "Workspace phone presentation")
        continueAfterFailure = false
        defer { UIPasteboard.general.items = [] }
        for appearance in ["light", "dark"] {
            let app = openQuestions(appearance: appearance)
            let attachment = app.buttons["question.attachment"]
            verifyMenu(attachment, in: app)

            let editor = app.descendants(matching: .any).matching(identifier: "question.freeText").firstMatch
            editor.tap()
            seedImageClipboard()
            paste(into: editor, in: app)
            let remove = app.buttons["question.removeImage"].firstMatch
            XCTAssertTrue(remove.waitForExistence(timeout: Self.timeout))
            XCTAssertTrue(app.images["Attached image 1"].exists)
            XCTAssertFalse(app.buttons["question.next"].isEnabled, "An attachment alone must not bypass the answer rules")
            remove.tap()
            XCTAssertTrue(remove.waitForNonExistence(timeout: Self.timeout))
            paste(into: editor, in: app)
            XCTAssertTrue(remove.waitForExistence(timeout: Self.timeout))
            capture(app, name: "question-image-\(appearance)")

            app.buttons["question.option.0"].tap()
            app.buttons["question.next"].tap()
            XCTAssertTrue(app.staticTexts["Question Two"].waitForExistence(timeout: Self.timeout))
            XCTAssertTrue(attachment.exists, "The attachment control belongs to every step")
            XCTAssertTrue(remove.exists)
            app.buttons["question.back"].tap()
            XCTAssertTrue(app.staticTexts["Question One"].waitForExistence(timeout: Self.timeout))
            XCTAssertTrue(remove.exists)
            app.buttons["question.collapse"].tap()
            XCTAssertTrue(app.buttons["question.answer"].waitForExistence(timeout: Self.timeout))
            XCTAssertFalse(app.buttons["Remove image 1"].exists, "Question attachments must not leak into the ordinary composer")
            app.buttons["question.answer"].tap()
            XCTAssertTrue(remove.waitForExistence(timeout: Self.timeout))
            app.buttons["question.next"].tap()
            XCTAssertTrue(app.staticTexts["Question Two"].waitForExistence(timeout: Self.timeout))
            app.buttons["question.skip"].tap()

            XCTAssertTrue(app.buttons["question.next"].waitForNonExistence(timeout: Self.timeout))
            let answer = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "A: Yes, confirmed")).firstMatch
            XCTAssertTrue(answer.waitForExistence(timeout: Self.timeout))
            let thumbnail = app.buttons["Attached image"].firstMatch
            XCTAssertTrue(thumbnail.waitForExistence(timeout: Self.timeout), "The echoed answer must contain the uploaded image")
            XCTAssertTrue(thumbnail.isHittable)
            capture(app, name: "question-image-sent-\(appearance)")
            thumbnail.tap()
            XCTAssertTrue(app.images["Image preview"].waitForExistence(timeout: Self.timeout), "The actual uploaded bytes must be readable")
            app.terminate()
        }
    }

    @MainActor
    private func verifyMenu(_ attachment: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(attachment.waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(attachment.label, "Add attachment")
        XCTAssertGreaterThanOrEqual(attachment.frame.width, 44)
        XCTAssertGreaterThanOrEqual(attachment.frame.height, 44)
        attachment.tap()
        XCTAssertTrue(app.buttons["Photos"].waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["Files"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
    }

    @MainActor
    private func openQuestions(appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "--demo-design-scenario=question-flow", "-appThemePreference", appearance]
        app.launch()
        let workspace = app.staticTexts["Workspace agent design"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
        workspace.tap()
        let agent = app.staticTexts["Continue Spec Writer"].firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: Self.timeout))
        agent.tap()
        let answer = app.buttons["question.answer"]
        XCTAssertTrue(answer.waitForExistence(timeout: Self.timeout))
        answer.tap()
        return app
    }

    @MainActor
    private func seedImageClipboard() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30))
        UIPasteboard.general.image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
    }

    @MainActor
    private func paste(into editor: XCUIElement, in app: XCUIApplication) {
        editor.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: Self.timeout))
        paste.tap()
        let allowPaste = app.alerts.buttons["Allow Paste"]
        if allowPaste.waitForExistence(timeout: 2) { allowPaste.tap() }
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
