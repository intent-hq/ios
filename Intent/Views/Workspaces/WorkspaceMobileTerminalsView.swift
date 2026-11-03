import SwiftUI

struct WorkspaceMobileTerminalsView: View {
    let workspaceId: String
    let store: MobileTerminalStore
    @Binding var revealedTarget: WorkspaceSwipeTarget?
    let onSelect: (MobileTerminal) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let terminals = store.activeTerminals(workspaceId: workspaceId)
        if !terminals.isEmpty {
            VStack(alignment: .leading, spacing: WorkspaceDetailStyle.sectionHeadingSpacing) {
                Text("Terminals")
                    .interFont(Constants.Typography.eyebrow)
                    .textCase(.uppercase)
                    .foregroundStyle(WorkspaceDetailStyle.secondary(for: colorScheme, contrast: contrast))
                    .accessibilityAddTraits(.isHeader)
                LazyVStack(spacing: WorkspaceDetailStyle.rowSpacing) {
                    ForEach(terminals) { terminal in
                        WorkspaceTerminalRow(terminal: terminal, store: store, revealedTarget: $revealedTarget, onSelect: onSelect)
                    }
                }
                .padding(.horizontal, -WorkspaceDetailStyle.pageInset)
            }
        }
    }
}

private struct WorkspaceTerminalRow: View {
    let terminal: MobileTerminal
    let store: MobileTerminalStore
    @Binding var revealedTarget: WorkspaceSwipeTarget?
    let onSelect: (MobileTerminal) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var confirmDelete = false
    @State private var isDeleting = false

    var body: some View {
        WorkspaceSwipeContainer(
            target: .terminal(terminal.id),
            revealedTarget: $revealedTarget,
            actionCount: 1,
            horizontalInset: WorkspaceDetailStyle.pageInset,
            showsSwipeTint: false
        ) { _ in
            terminalButton
        } actions: {
            deleteButton
        }
        .disabled(isDeleting)
        .alert("Delete terminal?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete terminal", role: .destructive, action: deleteTerminal)
        } message: {
            Text("This stops the shell and any commands running in it.")
        }
    }

    private var terminalButton: some View {
        Button {
            if revealedTarget != nil {
                revealedTarget = nil
            } else {
                store.clearError(workspaceId: terminal.workspaceId)
                onSelect(terminal)
            }
        } label: {
            terminalRow
        }
        .buttonStyle(TerminalRowButtonStyle())
        .visionListRowHitTarget()
        .contextMenu {
            Button("Delete terminal", role: .destructive) { confirmDelete = true }
                .disabled(!store.isConnected)
        }
        .accessibilityAction(named: "Delete terminal") {
            if store.isConnected { confirmDelete = true }
        }
    }

    private var deleteButton: some View {
        Button("Delete", role: .destructive) { confirmDelete = true }
            .buttonStyle(WorkspaceSwipeButtonStyle(color: .red))
            .accessibilityLabel("Delete terminal")
            .accessibilityIdentifier("terminal.delete.\(terminal.id)")
            .disabled(!store.isConnected)
    }

    private func deleteTerminal() {
        isDeleting = true
        revealedTarget = nil
        Task {
            _ = await store.close(terminal)
            isDeleting = false
        }
    }

    private struct TerminalRowButtonStyle: PrimitiveButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .onTapGesture { configuration.trigger() }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { configuration.trigger() }
        }
    }

    private var status: String? {
        if !store.isConnected { return "Disconnected" }
        return store.hasExitedProcess(terminal) ? "Exited" : nil
    }

    private var terminalRow: some View {
        let status = status
        return HStack(alignment: status == nil ? .center : .top, spacing: WorkspaceDetailStyle.avatarSpacing) {
            terminalIcon
            VStack(alignment: .leading, spacing: WorkspaceDetailStyle.noteTitleSpacing) {
                Text(store.title(for: terminal))
                    .interFont(Constants.Typography.bodyM)
                    .tracking(WorkspaceDetailStyle.rowTitleTracking)
                    .foregroundStyle(WorkspaceDetailStyle.foreground(for: colorScheme))
                if let status {
                    Text(status)
                        .interFont(Constants.Typography.bodyS)
                        .tracking(WorkspaceDetailStyle.bodyTracking)
                        .foregroundStyle(WorkspaceDetailStyle.secondary(for: colorScheme, contrast: colorSchemeContrast))
                }
            }
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: Constants.Accessibility.minimumTapTarget, alignment: status == nil ? .center : .top)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var terminalIcon: some View {
        Image(.terminal)
            .resizable()
            .scaledToFit()
            .frame(
                width: WorkspaceDetailStyle.avatarSize * WorkspaceDetailStyle.avatarArtRatio,
                height: WorkspaceDetailStyle.avatarSize * WorkspaceDetailStyle.avatarArtRatio
            )
            .foregroundStyle(.white)
            .frame(width: WorkspaceDetailStyle.avatarSize, height: WorkspaceDetailStyle.avatarSize)
            .background(WorkspaceDetailStyle.neutral, in: .rect(
                cornerRadius: WorkspaceDetailStyle.avatarSize * WorkspaceDetailStyle.avatarCornerRatio
            ))
            .accessibilityHidden(true)
    }
}
