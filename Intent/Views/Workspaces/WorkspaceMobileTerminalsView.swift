import SwiftUI

struct WorkspaceMobileTerminalsView: View {
    let workspaceId: String
    let store: MobileTerminalStore
    let onSelect: (MobileTerminal) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let terminals = store.activeTerminals(workspaceId: workspaceId)
        if !terminals.isEmpty {
            VStack(alignment: .leading, spacing: WorkspaceDetailStyle.sectionHeadingSpacing) {
                Text("Terminals")
                    .interFont(Constants.Typography.bodyM.withFace(.semibold))
                    .foregroundStyle(WorkspaceDetailStyle.foreground(for: colorScheme))
                    .accessibilityAddTraits(.isHeader)
                LazyVStack(spacing: WorkspaceDetailStyle.rowSpacing) {
                    ForEach(terminals) { terminal in
                        WorkspaceTerminalRow(terminal: terminal, store: store, onSelect: onSelect)
                    }
                }
            }
        }
    }
}

private struct WorkspaceTerminalRow: View {
    let terminal: MobileTerminal
    let store: MobileTerminalStore
    let onSelect: (MobileTerminal) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var actionWidth: CGFloat = 88
    @GestureState private var translation: CGFloat = 0
    @State private var isRevealed = false
    @State private var confirmDelete = false
    @State private var isDeleting = false

    private enum Layout {
        static let minimumDrag: CGFloat = 20
        static let revealThreshold: CGFloat = 30
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            terminalButton
                .offset(x: max(-actionWidth, min(0, (isRevealed ? -actionWidth : 0) + translation)))
            if isRevealed || translation < 0 { deleteButton }
        }
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(swipeGesture)
        .animation(reduceMotion ? nil : .snappy, value: isRevealed)
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
            if isRevealed {
                isRevealed = false
            } else {
                store.clearError(workspaceId: terminal.workspaceId)
                onSelect(terminal)
            }
        } label: {
            terminalRow
                .background(WorkspaceDetailStyle.background(for: colorScheme))
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
        Button(role: .destructive) { confirmDelete = true } label: {
            Text("Delete")
                .interFont(Constants.Typography.bodyXS)
                .frame(width: actionWidth)
                .frame(maxHeight: .infinity)
                .foregroundStyle(.white)
                .background(.red, in: .rect(cornerRadius: WorkspaceDetailStyle.checkboxCornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Delete terminal")
        .accessibilityIdentifier("terminal.delete.\(terminal.id)")
        .disabled(!store.isConnected)
        .allowsHitTesting(isRevealed)
        .accessibilityHidden(!isRevealed)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: Layout.minimumDrag)
            .updating($translation) { value, translation, _ in
                if abs(value.translation.width) > abs(value.translation.height) {
                    translation = value.translation.width
                }
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.translation.width < -Layout.revealThreshold {
                    isRevealed = true
                } else if value.translation.width > Layout.revealThreshold {
                    isRevealed = false
                }
            }
    }

    private func deleteTerminal() {
        isDeleting = true
        Task {
            _ = await store.close(terminal)
            isDeleting = false
            isRevealed = false
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

    private var terminalRow: some View {
        HStack(alignment: .top, spacing: WorkspaceDetailStyle.avatarSpacing) {
            terminalIcon
            VStack(alignment: .leading, spacing: WorkspaceDetailStyle.noteTitleSpacing) {
                Text(terminal.name)
                    .interFont(Constants.Typography.bodyM)
                    .tracking(WorkspaceDetailStyle.rowTitleTracking)
                    .foregroundStyle(WorkspaceDetailStyle.foreground(for: colorScheme))
                if !store.isConnected {
                    Text("Disconnected")
                        .interFont(Constants.Typography.bodyS)
                        .tracking(WorkspaceDetailStyle.bodyTracking)
                        .foregroundStyle(WorkspaceDetailStyle.secondary(for: colorScheme, contrast: colorSchemeContrast))
                }
            }
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: Constants.Accessibility.minimumTapTarget, alignment: .top)
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
