import UIKit
import XCTest

/// Exercises the real navigation, observation and reconciliation path for #446.
nonisolated final class CreateWorkspaceSelectionUITests: XCTestCase {
    private static let elementTimeout: TimeInterval = 15

    @MainActor
    func testLoadingTransitionsKeepSelectionTitlesStable() throws {
        continueAfterFailure = false
        let gate = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-selection-\(UUID().uuidString).trigger")
        defer { try? FileManager.default.removeItem(at: gate) }
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "--demo-workspace-selection-trigger-file=" + gate.path]
        app.launchArguments += ["-appThemePreference", ProcessInfo.processInfo.environment["INTENT_UITEST_APPEARANCE"] ?? "light"]
        app.launch()
        app.openHomeAction("workspace")
        try releaseSelectionLoading(in: app, step: "repository", gate: gate)
        let repository = app.buttons["creation.repository.nova-labs/console"]
        XCTAssertTrue(repository.waitForExistence(timeout: Self.elementTimeout))
        repository.tap()
        try FileManager.default.removeItem(at: gate)
        app.buttons["Next"].tap()
        try releaseSelectionLoading(in: app, step: "branch", gate: gate)
        XCTAssertTrue(app.buttons["creation.branch.main"].waitForExistence(timeout: Self.elementTimeout))
    }

    @MainActor
    private func releaseSelectionLoading(in app: XCUIApplication, step: String, gate: URL) throws {
        let title = app.staticTexts["creation.\(step)Title"]
        let spinner = app.activityIndicators["creation.\(step)Title.loading"]
        let search = app.buttons["creation.\(step)Search.open"]
        XCTAssertTrue(spinner.waitForExistence(timeout: Self.elementTimeout))
        XCTAssertTrue(title.exists)
        XCTAssertFalse(search.exists)
        let loadingTitleY = title.frame.minY
        attachEvidence(in: app, name: "\(step)-loading")
        try Data().write(to: gate)
        XCTAssertTrue(spinner.waitForNonExistence(timeout: Self.elementTimeout))
        XCTAssertTrue(search.waitForExistence(timeout: Self.elementTimeout))
        XCTAssertEqual(title.frame.minY, loadingTitleY, accuracy: 1)
        attachEvidence(in: app, name: "\(step)-loaded")
    }

    @MainActor
    func testRepositorySelectionSearchAndClose() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data"]
        app.launchArguments += ["-appThemePreference", ProcessInfo.processInfo.environment["INTENT_UITEST_APPEARANCE"] ?? "light"]
        app.launch()
        app.openHomeAction("workspace")
        let title = app.staticTexts["creation.repositoryTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: Self.elementTimeout))
        let next = app.buttons["Next"]
        XCTAssertFalse(next.isEnabled)
        let repository = app.buttons["creation.repository.nova-labs/console"]
        XCTAssertTrue(repository.waitForExistence(timeout: Self.elementTimeout))
        repository.tap()
        XCTAssertTrue(repository.isSelected)
        XCTAssertTrue(next.isEnabled)
        attachEvidence(in: app, name: "repository-selected")

        selectRepositoryThroughSearch(in: app, previous: repository)
        app.buttons["creation.repositorySearch.open"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Self.elementTimeout))
        let close = app.buttons["creation.close"]
        XCTAssertFalse(close.exists)
        XCTAssertFalse(next.exists)
        app.buttons["creation.repositorySearch.cancel"].tap()
        XCTAssertTrue(close.waitForExistence(timeout: Self.elementTimeout))
        XCTAssertTrue(next.isHittable)
        XCTAssertEqual(close.label, "Close")
        XCTAssertTrue(close.isHittable)
        close.tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: Self.elementTimeout))
        XCTAssertTrue(app.buttons["intent.menu.open"].waitForExistence(timeout: Self.elementTimeout))
    }

    @MainActor
    private func selectRepositoryThroughSearch(in app: XCUIApplication, previous: XCUIElement) {
        let search = app.textFields["creation.repositorySearch.field"]
        XCTAssertFalse(search.exists)
        let initialRowY = previous.frame.minY
        app.buttons["creation.repositorySearch.open"].tap()
        XCTAssertTrue(search.waitForExistence(timeout: Self.elementTimeout))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Self.elementTimeout))
        XCTAssertFalse(app.buttons["creation.close"].exists)
        XCTAssertFalse(app.buttons["Next"].exists)
        attachEvidence(in: app, name: "repository-search-opened")
        XCTAssertLessThan(previous.frame.minY, initialRowY)
        XCTAssertTrue(previous.isHittable)
        search.typeText("docs")
        let docs = app.buttons["creation.repository.nova-labs/docs"]
        XCTAssertTrue(docs.waitForExistence(timeout: Self.elementTimeout))
        XCTAssertTrue(previous.waitForNonExistence(timeout: Self.elementTimeout))
        XCTAssertTrue(docs.isHittable)
        docs.tap()
        XCTAssertTrue(docs.isSelected)
        attachEvidence(in: app, name: "repository-search-results")
        app.buttons["creation.repositorySearch.clear"].tap()
        XCTAssertTrue(previous.waitForExistence(timeout: Self.elementTimeout))
        XCTAssertFalse(previous.isSelected)
        XCTAssertTrue(docs.isSelected)
        checkSearchCancellation(in: app, prefix: "creation.repositorySearch", placeholder: "Search repositories", result: previous)
        XCTAssertTrue(docs.isSelected)
    }

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
        UIPasteboard.general.string = "Use this design"
        defer { UIPasteboard.general.items = [] }
        pasteClipboard(into: prompt, in: app)
        XCTAssertEqual(prompt.value as? String, "Use this design")
        seedImageClipboard()
        pasteClipboard(into: prompt, in: app)
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
    private func pasteClipboard(into editor: XCUIElement, in app: XCUIApplication) {
        editor.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: Self.elementTimeout))
        paste.tap()
        let allowPaste = app.alerts.buttons["Allow Paste"]
        if allowPaste.waitForExistence(timeout: 2) { allowPaste.tap() }
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
        for appearance in ["light", "dark"] {
            try assertProviderRefreshPreservesSelection(appearance: appearance)
        }
    }

    @MainActor
    private func assertProviderRefreshPreservesSelection(appearance: String) throws {
        let gate = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-provider-\(UUID().uuidString).trigger")
        defer { try? FileManager.default.removeItem(at: gate) }
        try Data().write(to: gate)
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-workspace-provider-trigger-file=" + gate.path]
        app.launchArguments += ["-appThemePreference", appearance]
        app.launch()
        defer { app.terminate() }
        openCreationForm(in: app)

        let provider = app.buttons["creation.providerPicker"]
        let model = app.buttons["creation.modelPicker"]
        XCTAssertTrue(provider.waitForExistence(timeout: Self.elementTimeout))
        provider.tap()
        app.buttons["Codex"].tap()
        XCTAssertTrue(model.waitForExistence(timeout: Self.elementTimeout))
        model.tap()
        app.buttons["Named Model"].tap()
        let reasoning = app.buttons["creation.reasoningPicker"]
        reasoning.tap()
        app.buttons["high"].tap()
        attachEvidence(in: app, name: "selected-before-back")
        assertSelections(in: app)

        app.buttons["creation.back"].tap()
        XCTAssertTrue(app.staticTexts["creation.branchTitle"].waitForExistence(timeout: Self.elementTimeout))
        try FileManager.default.removeItem(at: gate)
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["Loading providers..."].waitForExistence(timeout: Self.elementTimeout))
        XCTAssertFalse(provider.exists)
        XCTAssertFalse(model.exists)
        XCTAssertFalse(reasoning.exists)
        XCTAssertFalse(app.buttons["Create"].isEnabled)
        attachEvidence(in: app, name: "refresh-pending-\(appearance)")

        try Data().write(to: gate)
        XCTAssertTrue(provider.waitForExistence(timeout: Self.elementTimeout))
        assertSelections(in: app)
        XCTAssertEqual(reasoning.value as? String, "high")
        attachEvidence(in: app, name: "selected-after-refresh-\(appearance)")
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
        app.revealWorkspaceSource().tap()
        XCTAssertTrue(app.staticTexts["creation.branchTitle"].waitForExistence(timeout: Self.elementTimeout))
        app.buttons["creation.branchBack"].tap()
        XCTAssertTrue(app.staticTexts["creation.repositoryTitle"].waitForExistence(timeout: Self.elementTimeout))
        app.staticTexts["nova-labs/docs"].tap()
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["creation.branchTitle"].waitForExistence(timeout: Self.elementTimeout))
        selectBranchThroughSearch(in: app)
        app.buttons["Next"].tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: Self.elementTimeout))
        XCTAssertEqual(prompt.value as? String, draft)
        XCTAssertEqual(app.buttons["creation.sourceCard"].label, "Source. Repository: nova-labs/docs. Branch: feature/docs")
        assertSelections(in: app)
        attachEvidence(in: app, name: "draft-after-source-edit")
    }

    @MainActor
    private func selectBranchThroughSearch(in app: XCUIApplication) {
        let search = app.textFields["creation.branchSearch.field"]
        let main = app.buttons["creation.branch.main"]
        XCTAssertFalse(search.exists)
        let initialRowY = main.frame.minY
        app.buttons["creation.branchSearch.open"].tap()
        XCTAssertTrue(search.waitForExistence(timeout: Self.elementTimeout))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Self.elementTimeout))
        XCTAssertFalse(app.buttons["creation.branchBack"].exists)
        XCTAssertFalse(app.buttons["Next"].exists)
        attachEvidence(in: app, name: "branch-search-opened")
        XCTAssertLessThan(main.frame.minY, initialRowY)
        XCTAssertTrue(main.isHittable)
        search.typeText("feature")
        let feature = app.buttons["creation.branch.feature/docs"]
        XCTAssertTrue(feature.waitForExistence(timeout: Self.elementTimeout))
        XCTAssertTrue(main.waitForNonExistence(timeout: Self.elementTimeout))
        XCTAssertTrue(feature.isHittable)
        feature.tap()
        XCTAssertTrue(feature.isSelected)
        attachEvidence(in: app, name: "branch-search-results")
        app.buttons["creation.branchSearch.clear"].tap()
        XCTAssertTrue(main.waitForExistence(timeout: Self.elementTimeout))
        XCTAssertTrue(feature.isSelected)
        checkSearchCancellation(in: app, prefix: "creation.branchSearch", placeholder: "Search branches", result: main)
        XCTAssertTrue(feature.isSelected)
        app.buttons["creation.branchSearch.open"].tap()
        XCTAssertTrue(search.waitForExistence(timeout: Self.elementTimeout))
        search.typeText("feature")
        XCTAssertFalse(app.buttons["Next"].exists)
        app.buttons["creation.branchSearch.cancel"].tap()
        XCTAssertTrue(search.waitForNonExistence(timeout: Self.elementTimeout))
        XCTAssertTrue(app.buttons["creation.branchBack"].isHittable)
        XCTAssertTrue(app.buttons["Next"].isHittable)
    }
}

extension CreateWorkspaceSelectionUITests {
    @MainActor
    private func checkSearchCancellation(in app: XCUIApplication, prefix: String, placeholder: String, result: XCUIElement) {
        let search = app.textFields["\(prefix).field"]
        search.typeText("no-matching-source")
        XCTAssertTrue(result.waitForNonExistence(timeout: Self.elementTimeout))
        app.buttons["\(prefix).cancel"].tap()
        XCTAssertTrue(search.waitForNonExistence(timeout: Self.elementTimeout))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: Self.elementTimeout))
        XCTAssertTrue(result.waitForExistence(timeout: Self.elementTimeout))
        app.buttons["\(prefix).open"].tap()
        XCTAssertTrue(search.waitForExistence(timeout: Self.elementTimeout))
        XCTAssertEqual(search.value as? String, placeholder)
        app.buttons["\(prefix).cancel"].tap()
        XCTAssertTrue(search.waitForNonExistence(timeout: Self.elementTimeout))
    }

    @MainActor
    private func openCreationForm(in app: XCUIApplication) {
        app.openHomeAction("workspace")
        let repository = app.staticTexts["nova-labs/console"]
        XCTAssertTrue(repository.waitForExistence(timeout: Self.elementTimeout))
        repository.tap()
        attachEvidence(in: app, name: "selected-repository")
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["creation.branchTitle"].waitForExistence(timeout: Self.elementTimeout))
        let next = app.buttons["Next"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: next)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: Self.elementTimeout), .completed)
        app.buttons["creation.branch.main"].tap()
        attachEvidence(in: app, name: "selected-branch")
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
