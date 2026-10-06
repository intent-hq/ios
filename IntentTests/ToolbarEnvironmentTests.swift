@testable import Intent
import Observation
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite(.serialized)
struct ToolbarEnvironmentTests {
    @Test(arguments: [MenuKind.workspaces, .assistant])
    func menusSurviveNavigationBarVisibilityChangesWithoutInheritedObjects(menu: MenuKind) async throws {
        let connection = FakeConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(connectionManager: connection),
            connection: connection,
            persistence: .ephemeral()
        )
        let state = ToolbarState()
        let fixture = ToolbarFixture(
            menu: menu,
            state: state,
            store: AssistantStore(connection: connection),
            coordinator: coordinator
        )
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        // Native bar-item hosts must not need the window's observable environment (#745).
        let host = UIHostingController(rootView: fixture)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKey?.makeKey()
        }
        try await waitUntil("the navigation controller to mount") {
            navigationController(in: host) != nil
        }
        let navigation = try #require(navigationController(in: host))
        for hidden in [true, false, true, false] {
            state.isBarHidden = hidden
            try await waitUntil("the navigation bar to become \(hidden ? "hidden" : "visible")") {
                window.layoutIfNeeded()
                return navigation.isNavigationBarHidden == hidden
            }
            if !hidden {
                try await waitUntil("the menu button to be hosted in the visible navigation bar") {
                    guard let item = navigation.navigationBar.topItem else { return false }
                    // SwiftUI uses item groups on newer iOS versions instead of the legacy array.
                    let buttons = (item.rightBarButtonItems ?? []) + item.trailingItemGroups.flatMap(\.barButtonItems)
                    return buttons.contains { button in
                        button.menu != nil || button.customView != nil
                    }
                }
                #expect(navigation.navigationBar.window === window)
                #expect(navigation.navigationBar.bounds.height > 0)
            }
        }
    }

    enum MenuKind: Sendable {
        case workspaces
        case assistant
    }

    @Observable final class ToolbarState {
        var isBarHidden = true
    }

    private struct ToolbarFixture: View {
        let menu: MenuKind
        let state: ToolbarState
        let store: AssistantStore
        let coordinator: AppCoordinator

        var body: some View {
            NavigationStack {
                Text("Toolbar host")
                    .navigationTitle("Toolbar host")
                    .toolbar(state.isBarHidden ? .hidden : .visible, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            switch menu {
                            case .workspaces:
                                WorkspaceListMenu(
                                    showArchived: .constant(false),
                                    canCreateWorkspace: coordinator.canCreateWorkspace,
                                    onCreateWorkspace: {},
                                    onRecentAgents: {},
                                    onRecentConnections: {}
                                )
                            case .assistant:
                                Menu {
                                    AssistantHistoryMenu(store: store, coordinator: coordinator)
                                } label: {
                                    ToolbarOverflowLabel()
                                }
                            }
                        }
                        .intentToolbarSurface()
                    }
            }
        }
    }

    private func navigationController(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap { navigationController(in: $0) }.first
    }
}
