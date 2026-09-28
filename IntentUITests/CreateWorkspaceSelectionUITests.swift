import UIKit
import XCTest

/// Exercises the real navigation, observation and reconciliation path for #446.
nonisolated final class CreateWorkspaceSelectionUITests: XCTestCase {
    private static let elementTimeout: TimeInterval = 15

    @MainActor
    func testImagePasteSurvivesBackAndFailedCreationAndCanBeRemoved() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data"]
        app.launch()
        openCreationForm(in: app)
        let prompt = app.textViews["creation.prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: Self.elementTimeout))
        prompt.tap()
        prompt.typeText("Use this design")
        seedImageClipboard()
        defer { UIPasteboard.general.items = [] }
        prompt.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: Self.elementTimeout))
        paste.tap()
        let allowPaste = app.alerts.buttons["Allow Paste"]
        if allowPaste.waitForExistence(timeout: 2) { allowPaste.tap() }
        let remove = app.buttons["creation.removeImage"]
        XCTAssertTrue(remove.waitForExistence(timeout: Self.elementTimeout))
        XCTAssertEqual(prompt.value as? String, "Use this design")
        attachEvidence(in: app, name: "image-pasted-in-workspace-prompt")
        app.buttons["creation.back"].tap()
        app.buttons["Next"].tap()
        XCTAssertTrue(remove.waitForExistence(timeout: Self.elementTimeout))
        // Demo workspace.create returns no workspace: exercise the real failure UI,
        // without creating live data or adding a test-only production hook.
        app.buttons["Create"].tap()
        XCTAssertTrue(app.alerts["Error"].waitForExistence(timeout: Self.elementTimeout))
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(remove.exists)
        XCTAssertEqual(prompt.value as? String, "Use this design")
        cancelAttachmentPickers(in: app)
        XCTAssertTrue(remove.exists)
        remove.tap()
        XCTAssertFalse(remove.exists)
        XCTAssertEqual(prompt.value as? String, "Use this design")
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
    private func cancelAttachmentPickers(in app: XCUIApplication) {
        for picker in ["Photos", "Files"] {
            app.buttons["composer.attachment"].tap()
            app.buttons[picker].tap()
            let cancel = app.buttons["Cancel"]
            XCTAssertTrue(cancel.waitForExistence(timeout: Self.elementTimeout))
            cancel.tap()
            XCTAssertTrue(app.textViews["creation.prompt"].waitForExistence(timeout: Self.elementTimeout))
        }
    }

    @MainActor
    func testBackThenForwardPreservesProviderAndNamedModelThroughRefresh() throws {
        continueAfterFailure = false
        let gate = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-provider-\(UUID().uuidString).trigger")
        defer { try? FileManager.default.removeItem(at: gate) }
        try Data().write(to: gate)
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-workspace-provider-trigger-file=" + gate.path]
        if let appearance = ProcessInfo.processInfo.environment["INTENT_UITEST_APPEARANCE"] {
            app.launchArguments += ["-appThemePreference", appearance]
        }
        app.launch()
        openCreationForm(in: app)

        let provider = app.buttons["creation.providerPicker"]
        let model = app.buttons["creation.modelPicker"]
        XCTAssertTrue(provider.waitForExistence(timeout: Self.elementTimeout))
        provider.tap()
        app.buttons["Codex"].tap()
        XCTAssertTrue(model.waitForExistence(timeout: Self.elementTimeout))
        model.tap()
        app.buttons["Named Model"].tap()
        attachEvidence(in: app, name: "selected-before-back")
        assertSelections(in: app)

        app.buttons["creation.back"].tap()
        XCTAssertTrue(app.navigationBars["Select Branch"].waitForExistence(timeout: Self.elementTimeout))
        try FileManager.default.removeItem(at: gate)
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["Loading providers..."].waitForExistence(timeout: Self.elementTimeout))
        XCTAssertFalse(provider.exists)
        XCTAssertFalse(model.exists)
        XCTAssertFalse(app.buttons["Create"].isEnabled)
        attachEvidence(in: app, name: "refresh-pending")

        try Data().write(to: gate)
        XCTAssertTrue(provider.waitForExistence(timeout: Self.elementTimeout))
        attachEvidence(in: app, name: "selected-after-refresh")
        assertSelections(in: app)
        XCTAssertTrue(app.buttons["Create"].isEnabled)
        editSourceAndCheckDraft(in: app)
        // Never tap Create: this check only navigates and edits a draft.
    }

    @MainActor
    private func editSourceAndCheckDraft(in app: XCUIApplication) {
        let prompt = app.textViews["creation.prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: Self.elementTimeout))
        let draft = "Keep these instructions when editing the source."
        prompt.tap()
        prompt.typeText(draft)
        app.buttons["creation.sourceCard"].tap()
        XCTAssertTrue(app.navigationBars["Select Branch"].waitForExistence(timeout: Self.elementTimeout))
        app.navigationBars["Select Branch"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Select Repository"].waitForExistence(timeout: Self.elementTimeout))
        app.staticTexts["nova-labs/docs"].tap()
        app.buttons["Next"].tap()
        XCTAssertTrue(app.navigationBars["Select Branch"].waitForExistence(timeout: Self.elementTimeout))
        app.buttons["feature/docs"].tap()
        app.buttons["Next"].tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: Self.elementTimeout))
        XCTAssertEqual(prompt.value as? String, draft)
        XCTAssertEqual(app.buttons["creation.sourceCard"].label, "Source. Repository: nova-labs/docs. Branch: feature/docs")
        assertSelections(in: app)
        attachEvidence(in: app, name: "draft-after-source-edit")
    }

    @MainActor
    private func openCreationForm(in app: XCUIApplication) {
        app.openHomeAction("workspace")
        let repository = app.staticTexts["nova-labs/console"]
        XCTAssertTrue(repository.waitForExistence(timeout: Self.elementTimeout))
        repository.tap()
        app.buttons["Next"].tap()
        XCTAssertTrue(app.navigationBars["Select Branch"].waitForExistence(timeout: Self.elementTimeout))
        let next = app.buttons["Next"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: next)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: Self.elementTimeout), .completed)
        next.tap()
        let back = app.buttons["creation.back"]
        XCTAssertTrue(back.waitForExistence(timeout: Self.elementTimeout))
        XCTAssertEqual(back.label, "Back")
    }

    @MainActor
    private func assertSelections(in app: XCUIApplication) {
        XCTAssertEqual(app.buttons["creation.providerPicker"].value as? String, "Codex")
        XCTAssertEqual(app.buttons["creation.modelPicker"].value as? String, "Named Model")
        XCTAssertEqual(app.buttons["creation.specialistPicker"].value as? String, "Implementor")
    }

    @MainActor
    private func attachEvidence(in app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
