import SwiftUI

/// Workspace resources remain reachable from either the overview or an agent's rail.
struct WorkspaceResourceActions<Actions: View>: View {
    let workspaceId: String
    var isEnabled = true
    @ViewBuilder let actions: () -> Actions
    @Environment(\.workspaceUsesVerticalBar) private var usesVerticalBar

    var body: some View {
        VStack(spacing: IPadShellLayout.contextualRailSpacing) {
            actions()
            if usesVerticalBar, isEnabled {
                WorkspaceResourceShortcuts(workspaceId: workspaceId)
            }
        }
    }
}

struct WorkspaceResourceShortcuts: View {
    let workspaceId: String
    @Environment(BackendSession.self) private var session
    @State private var selectedTerminal: MobileTerminal?
    @State private var selectedBrowser: WorkspaceBrowser?
    @State private var createdBrowser: WorkspaceBrowser?
    @State private var showsNewBrowser = false
    @State private var terminalRequest: UUID?

    private var terminalStore: MobileTerminalStore { session.mobileTerminalStore }
    private var browserStore: WorkspaceBrowserStore { session.browserStore }
    private var workspaceName: String {
        session.workspaceStore.workspaces.first { $0.id == workspaceId }?.title ?? "New Workspace"
    }

    var body: some View {
        WorkspaceRailShortcuts(
            isTerminalDisabled: !terminalStore.isConnected || terminalStore.creatingWorkspaces.contains(workspaceId),
            onTerminal: openTerminal,
            onBrowser: openBrowser
        )
        .task(id: workspaceId) { await terminalStore.refresh(workspaceId: workspaceId) }
        .task(id: workspaceId) { await browserStore.refresh(workspaceId: workspaceId) }
        .onChange(of: workspaceId) { resetPresentation() }
        .onDisappear { terminalRequest = nil }
        .sheet(isPresented: $showsNewBrowser, onDismiss: presentCreatedBrowser) {
            NewWorkspaceBrowserView(workspaceId: workspaceId, store: browserStore) { createdBrowser = $0 }
                .coversConversationComposers()
        }
        .fullScreenCover(item: $selectedBrowser) { browser in
            WorkspaceBrowserView(browser: browser, connection: session.connection)
                .coversConversationComposers()
        }
        .fullScreenCover(item: $selectedTerminal, onDismiss: clearTerminalError) { terminal in
            MobileTerminalView(terminal: terminal, workspaceName: workspaceName, store: terminalStore)
                .coversConversationComposers()
        }
        .alert("Terminal unavailable", isPresented: Binding(
            get: { terminalStore.errorMessage(workspaceId: workspaceId) != nil && selectedTerminal == nil },
            set: { if !$0 { clearTerminalError() } }
        )) {
            Button("OK", action: clearTerminalError)
        } message: {
            Text(terminalStore.errorMessage(workspaceId: workspaceId) ?? "")
        }
    }

    private func openTerminal() {
        let requestedWorkspace = workspaceId
        let request = UUID()
        terminalRequest = request
        Task {
            let terminal = await terminalStore.openOrCreate(workspaceId: requestedWorkspace)
            if terminalRequest == request { selectedTerminal = terminal }
        }
    }

    private func openBrowser() {
        if let browser = browserStore.browsers(workspaceId: workspaceId).first {
            selectedBrowser = browser
        } else {
            showsNewBrowser = true
        }
    }

    private func presentCreatedBrowser() {
        selectedBrowser = createdBrowser
        createdBrowser = nil
    }

    private func clearTerminalError() { terminalStore.clearError(workspaceId: workspaceId) }

    private func resetPresentation() {
        terminalRequest = nil
        selectedTerminal = nil
        selectedBrowser = nil
        createdBrowser = nil
        showsNewBrowser = false
    }
}
