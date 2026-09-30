import Foundation
import Testing

/// Source contracts complement the native UI tests; they do not claim that
/// presentation, accessibility or system sharing has executed successfully.
struct DiagnosticExportEntryPointTests {
    @Test(arguments: [
        ("Settings/SettingsSupportSection.swift", "SettingsActionLabel(title: \"Export logs\""),
        ("Connection/ConnectionFailureView.swift", "Text(\"Export logs\"")
    ])
    func settingsAndFailureKeepAnOfflinePreviewEntry(file: String, labelPrefix: String) throws {
        let source = try read("Intent/Views/" + file)
        #expect(source.contains(labelPrefix))
        #expect(source.contains("showingDiagnosticLogs = true"))
        #expect(source.contains(".sheet(isPresented: $showingDiagnosticLogs)"))
        #expect(source.contains("DiagnosticExportView()"))
    }

    @Test func sharedPreviewHasNoBackendDependencyAndClearNeedsConfirmation() throws {
        let source = try read("Intent/Views/Settings/DiagnosticExportView.swift")
        #expect(!source.contains("@Environment(BackendSession.self)"))
        #expect(!source.contains("@Environment(AppCoordinator.self)"))
        let start = try #require(source.range(of: ".confirmationDialog(\"Clear local diagnostic logs?\""))
        let end = try #require(source.range(of: ".sheet(item:"))
        let confirmation = source[start.lowerBound..<end.lowerBound]
        #expect(confirmation.contains("titleVisibility: .visible"))
        #expect(confirmation.contains("Button(\"Clear logs\", role: .destructive) { model.clearHistory() }"))
        #expect(confirmation.contains("Button(\"Cancel\", role: .cancel) {}"))
        #expect(!confirmation.contains("message:"))
        #expect(!source.contains("DiagnosticPrivacySection"))
        #expect(!source.contains("About these logs"))
        #expect(source.contains("{ confirmsClear = true }"))
        // DiagnosticExportUITests verifies the visible Share ZIP action, independent of label construction.
        #expect(source.contains(".task { model.refresh() }"))
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: TestSourceInputs.url(for: path), encoding: .utf8)
    }
}
