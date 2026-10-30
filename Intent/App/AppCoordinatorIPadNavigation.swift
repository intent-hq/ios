import Foundation

extension AppCoordinator {
    func onSelectWorkspaceCommit(_ commit: WorkspaceCommit, workspaceId: String, gitRootId: String?) {
        workspaceChange = WorkspaceChangeDestination(workspaceId: workspaceId, gitRootId: gitRootId, content: .commit(commit))
        revealIPadWorkspaceRoute()
    }

    func onSelectWorkspaceFileDiff(_ file: WorkspaceChange, workspaceId: String, gitRootId: String?) {
        workspaceChange = WorkspaceChangeDestination(workspaceId: workspaceId, gitRootId: gitRootId, content: .file(file))
        revealIPadWorkspaceRoute()
    }

    func updateShellPresentation(_ enabled: Bool) {
        usesIPadShell = enabled
        guard enabled else { return }
        if selectedSection == .assistant {
            iPadNavigation.showAssistantDetail()
        } else if iPadNavigation.section == .assistant {
            iPadNavigation.showWorkspaceDetail()
        }
        ensureIPadWorkspaceSelection()
    }

    /// Embedded pairing dials a temporary session, so the window's connection
    /// was never borrowed and must not be torn down to repair it on success.
    func onIPadPairedConnection(_ connection: StoredConnection) {
        guard !lifecycleState.hasReturnedToSavedMachines else { return }
        let target = BackendID(connection.id)
        if backendID == target {
            dependencies.connection.updateCachedCredentials(
                hosts: connection.server.hosts,
                port: connection.server.port,
                token: connection.token,
                certFingerprint: connection.server.certFingerprint,
                tcAddress: connection.server.tcAddress
            )
        } else if let retargetWindow {
            retargetWindow(target)
        } else {
            onPaired(connection)
        }
    }

    /// Selecting a rail destination never switches this window's backend.
    func onSelectIPadSection(_ section: IPadSidebarSection) {
        if section == .assistant {
            guard canUseAssistant else { return }
            onSelectAssistant()
        } else if section == .workspaces {
            if showsIPadSidebarWorkspace { onBackToWorkspaceDetail() }
            selectedSection = .workspaces
        }
        iPadNavigation.selectSection(section)
        ensureIPadWorkspaceSelection()
    }

    /// Reselecting Workspaces while the sidebar shows the open workspace leaves it, like the main view's Back.
    private var showsIPadSidebarWorkspace: Bool {
        let navigation = iPadNavigation
        guard usesIPadShell, navigation.section == .workspaces, navigation.isSidebarVisible else { return false }
        let isPersistent = !navigation.usesSidebarOverlay && !navigation.usesCompactNavigation
        return WorkspaceSidebarContent.resolve(screen: currentScreen, isPersistent: isPersistent) != .workspaceList
    }

    /// Wide windows keep a detail selected; compact windows start with the list.
    func ensureIPadWorkspaceSelection() {
        guard usesIPadShell, iPadNavigation.hasMeasuredLayout, !iPadNavigation.usesCompactNavigation,
              iPadNavigation.section == .workspaces, iPadNavigation.pairing == nil,
              case .workspaceList = currentScreen else { return }
        let candidates = WorkspaceListViewModel(workspaceStore: dependencies.workspaceStore).filteredWorkspaces
        guard let workspace = candidates.first(where: { $0.id != Workspace.chiefWorkspaceId }) else { return }
        onSelectWorkspace(workspace.id)
    }

    /// Only explicit workspace selections move the shell. Background redirects
    /// (a missing workspace, reconnect restore) update the retained pane in place.
    func revealIPadWorkspaceRoute() {
        guard usesIPadShell else { return }
        iPadNavigation.showWorkspaceDetail()
    }

    func onIPadAssistantAccessChanged() {
        // Reconnecting keeps the current conversation. Only a known loss of
        // owner access evicts the Assistant's privileged presentation.
        guard dependencies.connection.currentPrincipal?.isOwner == false else { return }
        iPadNavigation.revokeAssistantAccess()
        if selectedSection == .assistant { selectedSection = .workspaces }
    }
}
