import SwiftUI

struct WorkspaceScriptRow: View {
    let script: WorkspaceScript
    let store: WorkspaceScriptStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isRevealed = false

    private var canUpdate: Bool { store.isConnected && !store.isUpdating(script) }

    private var status: String {
        guard store.isConnected else { return "Disconnected" }
        if store.isUpdating(script) { return "Updating" }
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
        WorkspaceSwipeContainer(isRevealed: $isRevealed, actionCount: script.isActive ? 2 : 1) { _ in
            scriptButton
        } actions: {
            swipeActions
        }
    }

    private var scriptButton: some View {
        Button {
            if isRevealed {
                isRevealed = false
            } else if !store.isLaunching(script) {
                Task { await store.launch(script) }
            }
        } label: {
            row
        }
        .buttonStyle(ScriptRowButtonStyle())
        .visionListRowHitTarget()
        .disabled(!canUpdate)
        .accessibilityIdentifier("workspace.script.\(script.id)")
        .contextMenu { menuActions }
        .accessibilityActions { menuActions }
    }

    private var swipeActions: some View {
        Group {
            if script.isActive {
                Button("Stop", action: stop)
                    .buttonStyle(WorkspaceSwipeButtonStyle(color: .orange))
                    .accessibilityLabel("Stop script")
                    .accessibilityIdentifier("workspace.script.stop.\(script.id)")
            }
            Button("Delete", role: .destructive, action: remove)
                .buttonStyle(WorkspaceSwipeButtonStyle(color: .red))
                .accessibilityLabel("Delete script")
                .accessibilityIdentifier("workspace.script.delete.\(script.id)")
        }
        .disabled(!canUpdate)
    }

    @ViewBuilder private var menuActions: some View {
        if script.isActive {
            Button("Stop script", systemImage: "stop.fill", action: stop).disabled(!canUpdate)
        }
        Button("Delete script", systemImage: "trash", role: .destructive, action: remove).disabled(!canUpdate)
    }

    private func stop() {
        isRevealed = false
        Task { await store.stop(script) }
    }

    private func remove() {
        isRevealed = false
        Task { await store.remove(script) }
    }

    private struct ScriptRowButtonStyle: PrimitiveButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .onTapGesture { configuration.trigger() }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { configuration.trigger() }
        }
    }

    private var row: some View {
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
            if store.isUpdating(script) || store.isLaunching(script) || ["starting", "restarting"].contains(script.status) {
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
}
