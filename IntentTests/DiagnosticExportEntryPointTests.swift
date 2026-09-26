import Foundation
import Testing

/// Source contracts complement the native UI tests; they do not claim that
/// presentation, accessibility or system sharing has executed successfully.
struct DiagnosticExportEntryPointTests {
    @Test(arguments: ["WorkspaceListView.swift", "WorkspaceListSidebar.swift"])
    func bothMenusKeepLiteralOrderAndOpenPreview(file: String) throws {
        let source = try read("Intent/Views/Workspaces/" + file)
        let settings = try #require(menuLabelRange("Settings", in: source))
        let connect = try #require(menuLabelRange("Connect to…", in: source))
        let export = try #require(menuLabelRange("Export logs", in: source))
        #expect(settings.lowerBound < connect.lowerBound)
        #expect(connect.lowerBound < export.lowerBound)
        #expect(!source[connect.upperBound..<export.lowerBound].contains("Label"))
        #expect(source.contains("showingDiagnosticLogs = true"))
        #expect(source.contains(".sheet(isPresented: $showingDiagnosticLogs) {\n            DiagnosticExportView()"))
        #expect(!source.contains("DiagnosticShareSheet"))
        if file == "WorkspaceListSidebar.swift" {
            let create = try #require(menuLabelRange("Create New Workspace", in: source))
            #expect(create.lowerBound < settings.lowerBound)
            #expect(source[settings.upperBound..<connect.lowerBound].contains("Divider()"))
        }
    }

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

    private func menuLabelRange(_ title: String, in source: String) -> Range<String.Index>? {
        // Match the user-facing label in either initializer form; font modifiers
        // and separating a native icon from its title must not change this contract.
        let pattern = #"Label\s*(?:\(\s*|\{\s*Text\(\s*)"#
            + "\"" + NSRegularExpression.escapedPattern(for: title) + "\""
        return source.range(of: pattern, options: .regularExpression)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: TestSourceInputs.url(for: path), encoding: .utf8)
    }
}
