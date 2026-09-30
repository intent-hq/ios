import SwiftUI

struct WorkspaceScriptRow: View {
    let script: WorkspaceScript
    let store: WorkspaceScriptStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var actionWidth: CGFloat = 88
    @State private var translation: CGFloat = 0
    @State private var isRevealed = false

    private var actionsWidth: CGFloat { script.isActive ? actionWidth * 2 : actionWidth }
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
        ZStack(alignment: .trailing) {
            scriptButton
                .offset(x: max(-actionsWidth, min(0, (isRevealed ? -actionsWidth : 0) + translation)))
            if isRevealed || translation < 0 { swipeActions }
        }
        .clipShape(RoundedRectangle(cornerRadius: BrowserAppearance.cornerRadius))
        .contentShape(Rectangle())
        .modifier(WorkspaceRowSwipeGesture(translation: $translation, isRevealed: $isRevealed))
        .animation(reduceMotion ? nil : .snappy, value: isRevealed)
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
        HStack(spacing: 0) {
            if script.isActive {
                Button(action: stop) { actionLabel("Stop", color: .orange) }
                    .accessibilityLabel("Stop script")
                    .accessibilityIdentifier("workspace.script.stop.\(script.id)")
            }
            Button(role: .destructive, action: remove) { actionLabel("Delete", color: .red) }
                .accessibilityLabel("Delete script")
                .accessibilityIdentifier("workspace.script.delete.\(script.id)")
        }
        .buttonStyle(.plain)
        .frame(width: actionsWidth)
        .disabled(!canUpdate)
        .allowsHitTesting(isRevealed)
        .accessibilityHidden(!isRevealed)
    }

    @ViewBuilder private var menuActions: some View {
        if script.isActive {
            Button("Stop script", systemImage: "stop.fill", action: stop).disabled(!canUpdate)
        }
        Button("Delete script", systemImage: "trash", role: .destructive, action: remove).disabled(!canUpdate)
    }

    private func actionLabel(_ title: String, color: Color) -> some View {
        Text(title)
            .interFont(Constants.Typography.bodyXS)
            .frame(width: actionWidth)
            .frame(minHeight: Constants.Accessibility.minimumTapTarget, maxHeight: .infinity)
            .foregroundStyle(.white)
            .background(color)
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
