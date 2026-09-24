import Foundation
import Testing

/// Source contracts complement the native UI tests; they do not claim that
/// presentation, accessibility or system sharing has executed successfully.
struct DiagnosticExportEntryPointTests {
    @Test(arguments: ["WorkspaceListView.swift", "WorkspaceListSidebar.swift"])
    func bothMenusKeepLiteralOrderAndOpenPreview(file: String) throws {
        let source = try read("Intent/Views/Workspaces/" + file)
        let settings = try #require(source.range(of: "Label(\"Settings\""))
        let connect = try #require(source.range(of: "Label(\"Connect to…\""))
        let export = try #require(source.range(of: "Label(\"Export logs\""))
        #expect(settings.lowerBound < connect.lowerBound)
        #expect(connect.lowerBound < export.lowerBound)
        #expect(!source[connect.upperBound..<export.lowerBound].contains("Label("))
        #expect(source.contains("showingDiagnosticLogs = true"))
        #expect(source.contains(".sheet(isPresented: $showingDiagnosticLogs) {\n            DiagnosticExportView()"))
        #expect(!source.contains("DiagnosticShareSheet"))
        if file == "WorkspaceListSidebar.swift" {
            let create = try #require(source.range(of: "Label(\"Create New Workspace\""))
            #expect(create.lowerBound < settings.lowerBound)
            #expect(source[settings.upperBound..<connect.lowerBound].contains("Divider()"))
        }
    }

    @Test(arguments: ["Settings/SettingsView.swift", "Connection/ConnectionFailureView.swift"])
    func settingsAndFailureKeepAnOfflinePreviewEntry(file: String) throws {
        let source = try read("Intent/Views/" + file)
        #expect(source.contains("Label(\"Export logs\""))
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
        #expect(source.contains("Button(\"Share ZIP\""))
        #expect(source.contains(".task { model.refresh() }"))
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: TestSourceInputs.url(for: path), encoding: .utf8)
    }
}