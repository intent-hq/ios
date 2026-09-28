import SwiftUI

struct WorkspaceScriptsView: View {
    let workspaceId: String
    let store: WorkspaceScriptStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let scripts = store.scripts(workspaceId: workspaceId)
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
                    .disabled(!store.isConnected || store.isLaunching(script))
                    .accessibilityIdentifier("workspace.script.menu.\(script.id)")
                }
            } label: {
                Label { Text("Scripts").interFont(Constants.Typography.bodyS) } icon: { Image(.terminal) }
            }
            .accessibilityIdentifier("workspace.scripts.menu")
        }
    }
}

private struct WorkspaceScriptRow: View {
    let script: WorkspaceScript
    let store: WorkspaceScriptStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var status: String {
        guard store.isConnected else { return "Disconnected" }
        if store.isLaunching(script) { return "Starting" }
        switch script.status {
        case "running": return "Running"
        case "starting": return "Starting"
        case "restarting": return "Restarting"
        case "exited": return script.error == nil ? "Finished" : "Failed"
        default: return "Ready"
        }
    }

    var body: some View {
        Button {
            Task { await store.launch(script) }
        } label: {
            HStack(spacing: WorkspaceDetailStyle.avatarSpacing) {
                Image(.terminal)
                    .resizable()
                    .scaledToFit()
                    .frame(width: WorkspaceDetailStyle.iconSize, height: WorkspaceDetailStyle.iconSize)
                    .frame(width: WorkspaceDetailStyle.avatarSize, height: WorkspaceDetailStyle.avatarSize)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: WorkspaceDetailStyle.noteTitleSpacing) {
                    Text(script.name)
                        .interFont(Constants.Typography.bodyM)
                        .foregroundStyle(WorkspaceDetailStyle.foreground(for: colorScheme))
                    Text(script.command)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                    Text(script.error ?? status)
                        .interFont(Constants.Typography.bodyXS)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if store.isLaunching(script) || ["starting", "restarting"].contains(script.status) {
                    ProgressView()
                } else {
                    Image(systemName: script.detectedURL == nil ? "play" : "globe")
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(WorkspaceDetailStyle.secondary(for: colorScheme, contrast: contrast))
            .frame(minHeight: Constants.Accessibility.minimumTapTarget)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .visionListRowHitTarget()
        .disabled(!store.isConnected || store.isLaunching(script))
        .accessibilityIdentifier("workspace.script.\(script.id)")
    }
}
