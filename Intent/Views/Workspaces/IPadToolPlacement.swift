import SwiftUI

private struct IPadToolDraggingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var iPadToolDraggingEnabled: Bool {
        get { self[IPadToolDraggingKey.self] }
        set { self[IPadToolDraggingKey.self] = newValue }
    }
}

struct IPadToolDragSource: ViewModifier {
    let tool: IPadWorkspaceTool
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.iPadToolDraggingEnabled) private var isEnabled

    func body(content: Content) -> some View {
        if isEnabled, coordinator.iPadNavigation.canPlaceTool {
            content
                .draggable(IPadToolDrag(
                    windowId: coordinator.iPadNavigation.toolDragWindowId,
                    toolId: tool.id,
                    workspaceId: tool.workspaceId
                )) {
                    Label(tool.title, systemImage: tool.isBrowser ? "globe" : "terminal")
                        .interFont(Constants.Typography.bodyM)
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: IPadSidebarStyle.rowRadius))
                }
                .accessibilityAction(named: "Open in main area") { coordinator.placeIPadTool(tool) }
        } else {
            content
        }
    }
}

struct IPadToolPlacementAction: View {
    let tool: IPadWorkspaceTool
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.iPadToolDraggingEnabled) private var isEnabled

    var body: some View {
        if isEnabled, coordinator.iPadNavigation.canPlaceTool {
            Button("Open in main area", systemImage: "rectangle.righthalf.inset.filled") {
                coordinator.placeIPadTool(tool)
            }
        }
    }
}

struct IPadToolDropTarget: ViewModifier {
    private static let targetOpacity = 0.85
    let session: BackendSession
    var isEnabled = true
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var colorScheme
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted, isEnabled, coordinator.iPadNavigation.canPlaceTool {
                    RoundedRectangle(cornerRadius: IPadShellLayout.cornerRadius)
                        .fill(IPadShellStyle.selection(for: colorScheme).opacity(Self.targetOpacity))
                        .overlay {
                            Label("Open in main area", systemImage: "rectangle.righthalf.inset.filled")
                                .interFont(Constants.Typography.bodyM)
                                .foregroundStyle(Theme.foreground(for: colorScheme))
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .dropDestination(for: IPadToolDrag.self) { items, _ in
                guard isEnabled, items.count == 1, let item = items.first,
                      item.windowId == coordinator.iPadNavigation.toolDragWindowId,
                      item.workspaceId == coordinator.selectedWorkspaceId else { return false }
                let tools = session.browserStore.browsers(workspaceId: item.workspaceId).map(IPadWorkspaceTool.browser)
                    + session.mobileTerminalStore.activeTerminals(workspaceId: item.workspaceId).map(IPadWorkspaceTool.terminal)
                guard let tool = tools.first(where: { $0.id == item.toolId }) else { return false }
                return coordinator.placeIPadTool(tool)
            } isTargeted: { isTargeted = $0 }
    }
}

private extension IPadWorkspaceTool {
    var isBrowser: Bool {
        if case .browser = self { return true }
        return false
    }
}

struct IPadWorkspaceToolView: View {
    let tool: IPadWorkspaceTool
    let session: BackendSession
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        Group {
            switch tool {
            case let .browser(browser):
                WorkspaceBrowserView(browser: browser, connection: session.connection) { close() }
            case let .terminal(terminal):
                MobileTerminalView(
                    terminal: terminal,
                    workspaceName: workspaceName,
                    store: session.mobileTerminalStore,
                    onClose: close
                )
            }
        }
    }

    private func close() { coordinator.iPadNavigation.closeTool() }

    private var workspaceName: String {
        session.workspaceStore.workspaces.first { $0.id == tool.workspaceId }?.title ?? "Workspace"
    }
}
