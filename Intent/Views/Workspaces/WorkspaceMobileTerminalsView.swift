import SwiftUI

struct WorkspaceMobileTerminalsView: View {
    let workspaceId: String
    let store: MobileTerminalStore
    let onSelect: (MobileTerminal) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
                        Button {
                            store.clearError(workspaceId: workspaceId)
                            onSelect(terminal)
                        } label: {
                            terminalRow(terminal)
                        }
                        .buttonStyle(.plain)
                        .visionListRowHitTarget()
                    }
                }
            }
        }
    }

    private func terminalRow(_ terminal: MobileTerminal) -> some View {
        HStack(alignment: .top, spacing: WorkspaceDetailStyle.avatarSpacing) {
            terminalIcon
            VStack(alignment: .leading, spacing: WorkspaceDetailStyle.noteTitleSpacing) {
                Text(terminal.name)
                    .interFont(Constants.Typography.bodyM)
                    .tracking(WorkspaceDetailStyle.rowTitleTracking)
                    .foregroundStyle(WorkspaceDetailStyle.foreground(for: colorScheme))
                Text(store.isConnected ? "Mobile terminal" : "Disconnected")
                    .interFont(Constants.Typography.bodyS)
                    .tracking(WorkspaceDetailStyle.bodyTracking)
                    .foregroundStyle(WorkspaceDetailStyle.secondary(for: colorScheme, contrast: colorSchemeContrast))
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
