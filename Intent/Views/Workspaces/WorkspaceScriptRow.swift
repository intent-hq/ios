import SwiftUI

struct WorkspaceScriptRow: View {
    private static let trailingIconInset: CGFloat = 12

    let script: WorkspaceScript
    let store: WorkspaceScriptStore
    @Binding var revealedTarget: WorkspaceSwipeTarget?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .body) private var scaledActionSize = Constants.WorkspaceList.swipeButtonSize
    @ScaledMetric(relativeTo: .body) private var actionIconSize = Constants.WorkspaceList.swipeButtonIconSize

    private var canUpdate: Bool { store.isConnected && !store.isUpdating(script) }
    private var actionSize: CGFloat { max(Constants.Accessibility.minimumTapTarget, scaledActionSize) }

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
        WorkspaceSwipeContainer(
            target: .script(script.id),
            revealedTarget: $revealedTarget,
            actionCount: script.isActive ? 2 : 1,
            actionWidth: actionSize,
            actionLeadingSpacing: Constants.WorkspaceList.swipeActionsLeadingSpacing,
            horizontalInset: WorkspaceDetailStyle.pageInset,
            swipeBackground: Constants.WorkspaceList.controlSurface(for: colorScheme),
            isSwipeEnabled: canUpdate
        ) { progress in
            scriptButton(swipeProgress: progress)
        } actions: {
            swipeActions
        }
    }

    private func scriptButton(swipeProgress: CGFloat) -> some View {
        Button {
            if revealedTarget != nil {
                revealedTarget = nil
            } else if !store.isLaunching(script) {
                Task { await store.launch(script) }
            }
        } label: {
            row(swipeProgress: swipeProgress)
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
                Button(action: stop) { actionIcon(.stopFill) }
                    .buttonStyle(WorkspaceSwipeIconButtonStyle(size: actionSize))
                    .accessibilityLabel("Stop script")
                    .accessibilityIdentifier("workspace.script.stop.\(script.id)")
            }
            Button(role: .destructive, action: remove) { actionIcon(.delete) }
                .buttonStyle(WorkspaceSwipeIconButtonStyle(size: actionSize))
                .accessibilityLabel("Delete script")
                .accessibilityIdentifier("workspace.script.delete.\(script.id)")
        }
        .disabled(!canUpdate)
    }

    private func actionIcon(_ image: ImageResource) -> some View {
        Image(image)
            .resizable()
            .scaledToFit()
            .frame(width: actionIconSize, height: actionIconSize)
    }

    @ViewBuilder private var menuActions: some View {
        if script.isActive {
            Button(action: stop) {
                Label { Text("Stop script") } icon: { Image(.stopFill) }
            }
            .disabled(!canUpdate)
        }
        Button(role: .destructive, action: remove) {
            Label { Text("Delete script") } icon: { Image(.delete) }
        }
        .disabled(!canUpdate)
    }

    private func stop() {
        revealedTarget = nil
        Task { await store.stop(script) }
    }

    private func remove() {
        revealedTarget = nil
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

    private func row(swipeProgress: CGFloat) -> some View {
        HStack(alignment: .top, spacing: WorkspaceDetailStyle.avatarSpacing) {
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
                Image(script.detectedURL == nil ? .play : .globe)
                    .resizable()
                    .scaledToFit()
                    .frame(width: WorkspaceDetailStyle.iconSize, height: WorkspaceDetailStyle.iconSize)
                    .opacity(1 - Double(swipeProgress))
                    .accessibilityHidden(true)
            }
        }
        .padding(.trailing, Self.trailingIconInset)
        .foregroundStyle(WorkspaceDetailStyle.secondary(for: colorScheme, contrast: contrast))
        .frame(minHeight: Constants.Accessibility.minimumTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
