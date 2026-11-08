import Foundation

extension AppCoordinator {
    func onSelectWorkspaceCommit(_ commit: WorkspaceCommit, workspaceId: String, gitRootId: String?) {
        iPadNavigation.closeTool()
        workspaceChange = WorkspaceChangeDestination(workspaceId: workspaceId, gitRootId: gitRootId, content: .commit(commit))
        revealIPadWorkspaceRoute()
    }

    func onSelectWorkspaceFileDiff(_ file: WorkspaceChange, workspaceId: String, gitRootId: String?) {
        iPadNavigation.closeTool()
        workspaceChange = WorkspaceChangeDestination(workspaceId: workspaceId, gitRootId: gitRootId, content: .file(file))
        revealIPadWorkspaceRoute()
    }

    func onSelectIPadPullRequest(_ item: PullRequestListItem) {
        iPadNavigation.closeTool()
        iPadPullRequest = item
        iPadNavigation.showPullRequestDetail()
    }

    func onCloseIPadPullRequest() {
        iPadNavigation.closePullRequestDetail()
        iPadPullRequest = nil
    }

    func updateShellPresentation(_ enabled: Bool) {
        usesIPadShell = enabled
        guard enabled else { return }
        if selectedSection == .assistant {
            iPadNavigation.showAssistantDetail()
        } else if iPadNavigation.section == .assistant {
            iPadNavigation.showWorkspaceDetail()
        }
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
            iPadNavigation.closeTool()
            if showsIPadSidebarWorkspace { onBackToWorkspaceDetail() }
            selectedSection = .workspaces
        }
        iPadNavigation.selectSection(section)
    }

    /// Reselecting Workspaces while the sidebar shows the open workspace leaves it, like the main view's Back.
    private var showsIPadSidebarWorkspace: Bool {
        let navigation = iPadNavigation
        guard usesIPadShell, navigation.section == .workspaces, navigation.isSidebarVisible else { return false }
        let isPersistent = !navigation.usesSidebarOverlay && !navigation.usesCompactNavigation
        return WorkspaceSidebarContent.resolve(screen: currentScreen, isPersistent: isPersistent) != .workspaceList
    }

    /// The workspace a wide window opens now: the top visible row of the user's list.
    var iPadAutoSelectedWorkspaceId: String? {
        let store = dependencies.workspaceStore
        return IPadWorkspaceAutoSelection(
            usesIPadShell: usesIPadShell,
            navigation: iPadNavigation,
            screen: currentScreen,
            includeArchived: store.showArchived,
            presentation: workspaceListPresentation
        ).workspaceId(in: store.workspaces)
    }

    /// The only auto-selection trigger: reruns whenever an input of the decision changes.
    func startObservingIPadAutoSelection() {
        withObservationTracking {
            _ = iPadAutoSelectedWorkspaceId
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                startObservingIPadAutoSelection()
                applyIPadAutoSelection()
            }
        }
    }

    /// Opens the decided workspace. Production calls arrive only from the observer above.
    func applyIPadAutoSelection() {
        guard !lifecycleState.hasReturnedToSavedMachines, let workspaceId = iPadAutoSelectedWorkspaceId else { return }
        onSelectWorkspace(workspaceId)
    }

    /// Only explicit workspace selections move the shell. Background redirects
    /// (a missing workspace, reconnect restore) update the retained pane in place.
    func revealIPadWorkspaceRoute() {
        guard usesIPadShell else { return }
        iPadNavigation.showWorkspaceDetail()
        if iPadNavigation.mainTool != nil { iPadNavigation.revealSidebar() }
    }

    @discardableResult
    func placeIPadTool(_ tool: IPadWorkspaceTool) -> Bool {
        guard usesIPadShell, selectedWorkspaceId == tool.workspaceId else { return false }
        workspaceChange = nil
        return iPadNavigation.placeTool(tool)
    }

    func onIPadAssistantAccessChanged() {
        // Reconnecting keeps the current conversation. Only a known loss of
        // owner access evicts the Assistant's privileged presentation.
        guard dependencies.connection.currentPrincipal?.isOwner == false else { return }
        iPadNavigation.revokeAssistantAccess()
        if selectedSection == .assistant { selectedSection = .workspaces }
    }
}
