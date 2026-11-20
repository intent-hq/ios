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

    private var showsIPadSidebarWorkspace: Bool {
        let navigation = iPadNavigation
        guard usesIPadShell, navigation.section == .workspaces, navigation.isSidebarVisible else { return false }
        let isPersistent = !navigation.usesSidebarOverlay && !navigation.usesCompactNavigation
        return WorkspaceSidebarContent.resolve(screen: currentScreen, isPersistent: isPersistent) != .workspaceList
    }

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

    func applyIPadAutoSelection() {
        guard !lifecycleState.hasReturnedToSavedMachines, let workspaceId = iPadAutoSelectedWorkspaceId else { return }
        onSelectWorkspace(workspaceId)
    }

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
        guard dependencies.connection.currentPrincipal?.isOwner == false else { return }
        iPadNavigation.revokeAssistantAccess()
        if selectedSection == .assistant { selectedSection = .workspaces }
    }
}
