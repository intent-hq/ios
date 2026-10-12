import Foundation

extension AppCoordinator {
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
            selectedSection = .workspaces
        }
        iPadNavigation.selectSection(section)
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
