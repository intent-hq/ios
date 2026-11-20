import SwiftUI
import UIKit

extension EnvironmentValues {
    @Entry var isAgentHistoryOpen = false
    @Entry var openAgentHistory = OpenAgentHistoryAction()
}

struct OpenAgentHistoryAction {
    var isPresented: Binding<Bool>?
    var isEnabled = false

    func callAsFunction() {
        if isEnabled { isPresented?.wrappedValue = true }
    }
}

struct AgentHistoryDrawer<Content: View>: View {
    let isEnabled: Bool
    @ViewBuilder let content: Content
    @Environment(AppCoordinator.self) private var coordinator
    @State private var isPresented = false

    var body: some View {
        EdgeDrawer(
            side: .right,
            isPresented: $isPresented,
            isEnabled: isEnabled,
            closeLabel: "Close agent history",
            closeIdentifier: "agent-history.close",
            onReveal: dismissKeyboard
        ) {
            AgentHistoryList(onSelect: select)
        } content: {
            content
                .environment(\.isAgentHistoryOpen, isPresented)
                .environment(\.openAgentHistory, OpenAgentHistoryAction(
                    isPresented: $isPresented,
                    isEnabled: isEnabled
                ))
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func select(_ entry: AgentHistoryEntry) {
        isPresented = false
        coordinator.onSelectHistoryEntry(entry)
    }
}
