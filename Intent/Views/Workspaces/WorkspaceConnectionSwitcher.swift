import SwiftUI

extension EnvironmentValues {
    @Entry var openConnectionSwitcher = OpenConnectionSwitcherAction()
}

/// Stores the drawer's state rather than an incomparable environment closure.
struct OpenConnectionSwitcherAction {
    var isPresented: Binding<Bool>?
    var isEnabled = false

    func callAsFunction() {
        if isEnabled { isPresented?.wrappedValue = true }
    }
}

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
    @Environment(\.isAgentHistoryOpen) private var isAgentHistoryOpen
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.openWindow) private var openWindow

    private var canReveal: Bool { isEnabled && !isAgentHistoryOpen }

    var body: some View {
        EdgeDrawer(
            side: .left,
            isPresented: $isPresented,
            isEnabled: canReveal,
            closeLabel: "Close connection switcher",
            closeIdentifier: "connection-switcher.close",
            onReveal: onReveal
        ) {
            ConnectionSwitcherList(
                connections: coordinator.savedConnections,
                selectedID: coordinator.backendID?.connectionID,
                onSelect: select,
                onOpenInNewWindow: newWindowAction
            )
        } content: {
            content
                .environment(\.openConnectionSwitcher, OpenConnectionSwitcherAction(
                    isPresented: $isPresented,
                    isEnabled: canReveal
                ))
        }
        .preference(key: ConnectionSwitcherOpenPreference.self, value: isPresented)
    }

    private func select(_ id: UUID) {
        isPresented = false
        if id != coordinator.backendID?.connectionID {
            coordinator.onSwitchConnection(id: id)
        }
    }

    /// Long-press only, and nil on iPhone where windows cannot be added.
    private var newWindowAction: ((UUID) -> Void)? {
        guard supportsMultipleWindows else { return nil }
        let openWindow = openWindow
        let isPresented = $isPresented
        return { id in
            isPresented.wrappedValue = false
            openWindow(value: BackendID(id))
        }
    }
}
