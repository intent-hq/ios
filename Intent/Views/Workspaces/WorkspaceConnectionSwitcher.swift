import SwiftUI

/// True while the Connections switcher is open, so the global agent history
/// drawer does not compete for the same horizontal pans.
struct ConnectionSwitcherOpenPreference: PreferenceKey {
    nonisolated static var defaultValue: Bool { false }

    nonisolated static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

struct WorkspaceConnectionSwitcher<Content: View>: View {
    @Binding var isPresented: Bool
    let isEnabled: Bool
    let onReveal: () -> Void
    @ViewBuilder let content: Content
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        EdgeDrawer(
            side: .left,
            isPresented: $isPresented,
            isEnabled: isEnabled,
            closeLabel: "Close connection switcher",
            closeIdentifier: "connection-switcher.close",
            onReveal: onReveal
        ) {
            ConnectionSwitcherList(
                connections: coordinator.savedConnections,
                selectedID: coordinator.backendID?.connectionID,
                onSelect: select
            )
        } content: {
            content
        }
        .preference(key: ConnectionSwitcherOpenPreference.self, value: isPresented)
    }

    private func select(_ id: UUID) {
        isPresented = false
        if id != coordinator.backendID?.connectionID {
            coordinator.onSwitchConnection(id: id)
        }
    }
}
