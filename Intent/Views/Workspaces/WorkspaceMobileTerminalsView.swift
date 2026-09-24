import SwiftUI

struct WorkspaceMobileTerminalsView: View {
    let workspaceId: String
    let store: MobileTerminalStore
    let onSelect: (MobileTerminal) -> Void

    var body: some View {
        let terminals = store.activeTerminals(workspaceId: workspaceId)
        if !terminals.isEmpty {
            Text("Terminals")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical)
            ForEach(terminals) { terminal in
                Button {
                    store.clearError()
                    onSelect(terminal)
                } label: {
                    HStack {
                        Label(terminal.name, systemImage: "terminal")
                        Spacer()
                        if !store.isConnected {
                            Text("Disconnected").font(.caption)
                        }
                        Image(systemName: "chevron.right")
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .visionListRowHitTarget()
            }
        }
    }
}
