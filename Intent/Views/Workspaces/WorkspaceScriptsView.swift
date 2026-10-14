import SwiftUI

struct WorkspaceScriptsView: View {
    let workspaceId: String
    let store: WorkspaceScriptStore
    @Binding var revealedTarget: WorkspaceSwipeTarget?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let scripts = store.scriptsWithRuns(workspaceId: workspaceId)
        let rows = scripts.map { script in
            (id: script.id, content: WorkspaceScriptRow(script: script, store: store, revealedTarget: $revealedTarget))
        }
        if !scripts.isEmpty || store.errorMessage(workspaceId: workspaceId) != nil {
            VStack(alignment: .leading, spacing: WorkspaceDetailStyle.sectionHeadingSpacing) {
                Text("Scripts")
                    .interFont(Constants.Typography.eyebrow)
                    .textCase(.uppercase)
                    .foregroundStyle(WorkspaceDetailStyle.secondary(for: colorScheme, contrast: contrast))
                    .accessibilityAddTraits(.isHeader)
                LazyVStack(spacing: WorkspaceDetailStyle.rowSpacing) {
                    ForEach(rows, id: \.id) { @Sendable row in row.content }
                }
                .padding(.horizontal, -WorkspaceDetailStyle.pageInset)
                if let error = store.errorMessage(workspaceId: workspaceId) {
                    VStack(alignment: .leading) {
                        Text(error).interFont(Constants.Typography.bodyXS)
                        Button("Retry") { Task { await store.refresh(workspaceId: workspaceId) } }
                            .buttonStyle(IntentButtonStyle(variant: .secondary))
                            .disabled(!store.isConnected)
                    }
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                }
            }
        }
    }
}

struct WorkspaceScriptsMenu: View {
    let workspaceId: String
    let store: WorkspaceScriptStore

    var body: some View {
        let scripts = store.scripts(workspaceId: workspaceId)
        // Read launch/connection state on MainActor, leaving only actions deferred.
        let rows = scripts.map { script in
            let content = Button {
                Task { await store.launch(script) }
            } label: {
                Label { Text(script.name) } icon: { Image(script.detectedURL == nil ? .play : .globe) }
            }
            .disabled(!store.isConnected || store.isLaunching(script) || store.isUpdating(script))
            .accessibilityIdentifier("workspace.script.menu.\(script.id)")
            return (id: script.id, content: content)
        }
        if !scripts.isEmpty {
            Menu {
                ForEach(rows, id: \.id) { @Sendable row in row.content }
            } label: {
                Label { Text("Scripts").interFont(Constants.Typography.bodyS) } icon: { Image(.code) }
            }
            .accessibilityIdentifier("workspace.scripts.menu")
        }
    }
}
