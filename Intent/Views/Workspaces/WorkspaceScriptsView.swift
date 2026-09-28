import SwiftUI

struct WorkspaceScriptsView: View {
    let workspaceId: String
    let store: WorkspaceScriptStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let scripts = store.scriptsWithRuns(workspaceId: workspaceId)
        if !scripts.isEmpty || store.errorMessage(workspaceId: workspaceId) != nil {
            VStack(alignment: .leading, spacing: WorkspaceDetailStyle.sectionHeadingSpacing) {
                Text("Scripts")
                    .interFont(Constants.Typography.bodyM.withFace(.semibold))
                    .foregroundStyle(WorkspaceDetailStyle.foreground(for: colorScheme))
                    .accessibilityAddTraits(.isHeader)
                LazyVStack(spacing: WorkspaceDetailStyle.rowSpacing) {
                    ForEach(scripts) { script in
                        WorkspaceScriptRow(script: script, store: store)
                    }
                }
                if let error = store.errorMessage(workspaceId: workspaceId) {
                    VStack(alignment: .leading) {
                        Text(error).interFont(Constants.Typography.bodyXS)
                        Button("Retry") { Task { await store.refresh(workspaceId: workspaceId) } }
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
        if !scripts.isEmpty {
            Menu {
                ForEach(scripts) { script in
                    Button {
                        Task { await store.launch(script) }
                    } label: {
                        Label(script.name, systemImage: script.detectedURL == nil ? "play" : "globe")
                    }
                    .disabled(!store.isConnected || store.isLaunching(script) || store.isUpdating(script))
                    .accessibilityIdentifier("workspace.script.menu.\(script.id)")
                }
            } label: {
                Label { Text("Scripts").interFont(Constants.Typography.bodyS) } icon: { Image(.terminal) }
            }
            .accessibilityIdentifier("workspace.scripts.menu")
        }
    }
}
