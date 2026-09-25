import SwiftUI

struct WorkspaceMobileTerminalsView: View {
    let workspaceId: String
    let store: MobileTerminalStore
    let onSelect: (MobileTerminal) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let terminals = store.activeTerminals(workspaceId: workspaceId)
        if !terminals.isEmpty {
            Text("Terminals")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical)
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

    private func terminalRow(_ terminal: MobileTerminal) -> some View {
        HStack(spacing: TerminalAppearance.headerSpacing) {
            Image(systemName: "terminal")
                .font(.headline)
                .foregroundStyle(TerminalAppearance.green)
                .frame(width: TerminalAppearance.controlSize, height: TerminalAppearance.controlSize)
                .background(TerminalAppearance.background, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: TerminalAppearance.groupInset) {
                Text(terminal.name).font(.subheadline.weight(.semibold))
                Text(store.isConnected ? "Mobile terminal" : "Disconnected")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .accessibilityHidden(true)
        }
        .padding(TerminalAppearance.terminalInset)
        .background(Theme.card(for: colorScheme), in: RoundedRectangle(cornerRadius: TerminalAppearance.rowCornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: TerminalAppearance.rowCornerRadius))
        .accessibilityElement(children: .combine)
    }
}
