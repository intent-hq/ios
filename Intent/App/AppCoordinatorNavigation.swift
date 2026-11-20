import Foundation

private enum AppCoordinatorNavigationConstants {
    static let invalidParametersErrorCode = -32_602
}

final class AppCoordinatorNavigationState {
    enum ScreenRestorationClaim {
        case resolved(Bool)
        case unclaimed
    }

    var suppressWorkspaceNavigation = false
    var claimedScreenRestoration = ScreenRestorationClaim.unclaimed
    var recentWorkspaceAgentRequestId: UUID?
}

extension AppCoordinator {
    private var restoresLastScreen: Bool {
        if case let .resolved(claimed) = navigationState.claimedScreenRestoration { return claimed }
        let claimed = dependencies.claimScreenRestoration()
        navigationState.claimedScreenRestoration = .resolved(claimed)
        return claimed
    }

    func restoreLastScreenIfAvailable() -> Bool {
        guard restoresLastScreen,
              let connectionID = windowConnectionID,
              let saved = dependencies.persistence.loadLastScreen(for: connectionID) else { return false }
        switch saved.screen {
        case "workspaceDetail":
            guard let workspaceId = saved.workspaceId else { return false }
            markWorkspaceSeen(workspaceId)
            navigationState.suppressWorkspaceNavigation = true
            selectedWorkspaceId = workspaceId
            navigationState.suppressWorkspaceNavigation = false
            currentScreen = .workspaceDetail(workspaceId: workspaceId)
            return true
        case "conversation":
            return restoreConversation(saved)
        case "note":
            guard let noteId = saved.noteId,
                  let workspaceId = saved.workspaceId,
                  let noteTitle = saved.noteTitle else { return false }
            markWorkspaceSeen(workspaceId)
            navigationState.suppressWorkspaceNavigation = true
            selectedWorkspaceId = workspaceId
            navigationState.suppressWorkspaceNavigation = false
            currentScreen = .noteDetail(
                noteId: noteId,
                workspaceId: workspaceId,
                noteTitle: noteTitle
            )
            Task { @MainActor in
                await self.validateRestoredNote(noteId: noteId, workspaceId: workspaceId)
            }
            return true
        default:
            return false
        }
    }

    private func restoreConversation(_ saved: PersistenceManager.SavedScreen) -> Bool {
        guard let agentId = saved.agentId,
              let workspaceId = saved.workspaceId,
              let agentName = saved.agentName else { return false }
        if workspaceId == Workspace.chiefWorkspaceId {
            currentScreen = .workspaceList
            onSelectAgent(agentId, workspaceId: workspaceId, agentName: agentName)
            return true
        }
        markWorkspaceSeen(workspaceId)
        navigationState.suppressWorkspaceNavigation = true
        selectedWorkspaceId = workspaceId
        navigationState.suppressWorkspaceNavigation = false
        currentScreen = .agentConversation(agentId: agentId, workspaceId: workspaceId, agentName: agentName)
        Task { @MainActor in
            await self.validateRestoredAgent(agentId: agentId, workspaceId: workspaceId)
        }
        return true
    }

    func revalidateCurrentAgentAfterReconnect() {
        if case let .agentConversation(agentId, workspaceId, _) = currentScreen {
            Task { @MainActor in
                await self.validateRestoredAgent(agentId: agentId, workspaceId: workspaceId)
            }
        }
    }

    func onSelectWorkspace(_ workspaceId: String) {
        iPadNavigation.closeTool()
        if workspaceId == Workspace.chiefWorkspaceId {
            onSelectAssistant()
            return
        }
        selectedSection = .workspaces
        markWorkspaceSeen(workspaceId)
        selectedWorkspaceId = workspaceId
        currentScreen = .workspaceDetail(workspaceId: workspaceId)
        saveCurrentScreen()
        revealIPadWorkspaceRoute()
    }

    @discardableResult
    func onOpenRecentWorkspaceAgent(_ workspaceId: String) -> Task<Void, Never> {
        onSelectWorkspace(workspaceId)
        guard workspaceId != Workspace.chiefWorkspaceId else { return Task {} }
        let requestId = UUID()
        navigationState.recentWorkspaceAgentRequestId = requestId
        return Task { @MainActor [weak self, connection = dependencies.connection] in
            guard self?.navigationState.recentWorkspaceAgentRequestId == requestId, !Task.isCancelled else { return }
            defer {
                if self?.navigationState.recentWorkspaceAgentRequestId == requestId {
                    self?.navigationState.recentWorkspaceAgentRequestId = nil
                }
            }
            do {
                let result = try await PagedReads.requestAgentList(["workspaceId": workspaceId], connection: connection) {
                    self?.recentAgentLookupIsCurrent(requestId, workspaceId: workspaceId) == true
                }
                guard let self, recentAgentLookupIsCurrent(requestId, workspaceId: workspaceId),
                      let response = result as? [String: Any],
                      let rows = response["agents"] as? [[String: Any]],
                      let agent = rows.compactMap(AgentSession.parseAgent)
                          .filter({ $0.retiredAt == nil })
                          .min(by: AgentListViewModel.byLastActivity) else { return }
                onSelectAgent(agent.id, workspaceId: workspaceId, agentName: agent.name)
            } catch is CancellationError {
            } catch {
                AppLog.app.error("[AppCoordinator] Recent workspace agent lookup failed: \(error)")
            }
        }
    }

    private func recentAgentLookupIsCurrent(_ requestId: UUID, workspaceId: String) -> Bool {
        guard !Task.isCancelled, navigationState.recentWorkspaceAgentRequestId == requestId,
              selectedSection == .workspaces,
              case let .workspaceDetail(currentWorkspaceId) = currentScreen else { return false }
        return currentWorkspaceId == workspaceId
    }

    private func markWorkspaceSeen(_ workspaceId: String) {
        dependencies.workspaceStore.clearUnreadAttentionLocally(workspaceId: workspaceId)
        Task { @MainActor in
            do {
                _ = try await dependencies.connection.request(
                    "workspace.markSeen",
                    params: ["workspaceId": workspaceId]
                )
            } catch {
                AppLog.app.error("[AppCoordinator] workspace.markSeen failed: \(error)")
            }
        }
    }

    func handleMissingWorkspace() {
        if let connectionID = windowConnectionID {
            dependencies.persistence.clearLastScreen(for: connectionID)
        }
        selectedWorkspaceId = nil
        currentScreen = .workspaceList
        if usesIPadShell, iPadNavigation.section == .workspaces, iPadAutoSelectedWorkspaceId == nil {
            iPadNavigation.revealSidebar()
        }
    }

    func onBackToWorkspaceList() {
        if usesIPadShell {
            onSelectIPadSection(.workspaces)
            return
        }
        selectedWorkspaceId = nil
        currentScreen = .workspaceList
        guard restoresLastScreen, let connectionID = windowConnectionID else { return }
        dependencies.persistence.saveLastScreen(
            PersistenceManager.SavedScreen(
                screen: "workspaceList",
                workspaceId: nil,
                agentId: nil,
                agentName: nil,
                noteId: nil,
                noteTitle: nil
            ),
            for: connectionID
        )
    }

    func onSelectAgent(_ agentId: String, workspaceId: String, agentName: String) {
        if workspaceId == Workspace.chiefWorkspaceId {
            onSelectAssistant(agentId: agentId)
            return
        }
        selectedSection = .workspaces
        navigationState.suppressWorkspaceNavigation = true
        selectedWorkspaceId = workspaceId
        navigationState.suppressWorkspaceNavigation = false
        conversationRequestId += 1
        currentScreen = .agentConversation(agentId: agentId, workspaceId: workspaceId, agentName: agentName)
        saveCurrentScreen()
        revealIPadWorkspaceRoute()
    }

    func onSelectAssistant(agentId: String? = nil) {
        guard canUseAssistant else { return }
        if let agentId { assistantAgentId = agentId }
        selectedSection = .assistant
        switch currentScreen {
        case .workspaceList, .workspaceDetail, .agentConversation, .noteDetail:
            break
        default:
            if let selectedWorkspaceId {
                currentScreen = .workspaceDetail(workspaceId: selectedWorkspaceId)
            } else {
                currentScreen = .workspaceList
            }
        }
        if usesIPadShell { iPadNavigation.showAssistantDetail() }
    }

    func onSelectNote(_ noteId: String, workspaceId: String, noteTitle: String) {
        iPadNavigation.closeTool()
        selectedSection = .workspaces
        currentScreen = .noteDetail(noteId: noteId, workspaceId: workspaceId, noteTitle: noteTitle)
        saveCurrentScreen()
        revealIPadWorkspaceRoute()
    }

    func onBackFromNote() {
        if let workspaceId = selectedWorkspaceId {
            currentScreen = .workspaceDetail(workspaceId: workspaceId)
            saveCurrentScreen()
        }
    }

    func onBackToWorkspaceDetail() {
        if let workspaceId = selectedWorkspaceId {
            currentScreen = .workspaceDetail(workspaceId: workspaceId)
            saveCurrentScreen()
        }
    }

    private func saveCurrentScreen() {
        guard restoresLastScreen else { return }
        let saved: PersistenceManager.SavedScreen
        switch currentScreen {
        case let .workspaceDetail(workspaceId):
            saved = PersistenceManager.SavedScreen(
                screen: "workspaceDetail",
                workspaceId: workspaceId,
                agentId: nil,
                agentName: nil,
                noteId: nil,
                noteTitle: nil
            )
        case let .agentConversation(agentId, workspaceId, agentName):
            saved = PersistenceManager.SavedScreen(
                screen: "conversation",
                workspaceId: workspaceId,
                agentId: agentId,
                agentName: agentName,
                noteId: nil,
                noteTitle: nil
            )
        case let .noteDetail(noteId, workspaceId, noteTitle):
            saved = PersistenceManager.SavedScreen(
                screen: "note",
                workspaceId: workspaceId,
                agentId: nil,
                agentName: nil,
                noteId: noteId,
                noteTitle: noteTitle
            )
        default:
            return
        }
        guard let connectionID = windowConnectionID else { return }
        dependencies.persistence.saveLastScreen(saved, for: connectionID)
    }

    func validateRestoredAgent(agentId: String, workspaceId: String) async {
        do {
            _ = try await agentDetails.load(agentId: agentId, workspaceId: workspaceId)
        } catch is AgentDetailError {
            handleMissingAgent(agentId: agentId, workspaceId: workspaceId)
        } catch {
            AppLog.app.error("[AppCoordinator] Agent validation failed: \(error)")
            let nsError = error as NSError
            if nsError.isEntityNotFound {
                handleMissingAgent(agentId: agentId, workspaceId: workspaceId)
            } else if nsError.domain == "WebSocket",
                      nsError.code == AppCoordinatorNavigationConstants.invalidParametersErrorCode {
                AppLog.app.warning(
                    "[AppCoordinator] UNEXPECTED -32602 without data.code == \"not-found\" for "
                        + "agent \(agentId) (data.code: \(nsError.intentErrorDataCode ?? "absent")) — "
                        + "NOT treating as deletion: \(nsError.localizedDescription)"
                )
            }
        }
    }

    func handleMissingAgent(agentId: String, workspaceId: String) {
        if case let .agentConversation(aId, wsId, _) = currentScreen,
           aId == agentId, wsId == workspaceId {
            currentScreen = .workspaceDetail(workspaceId: workspaceId)
            saveCurrentScreen()
        }
    }

    func validateRestoredNote(noteId: String, workspaceId: String, noteStore: NoteStore? = nil) async {
        let store = noteStore ?? NoteStore(connectionManager: dependencies.connection)
        if case .notFound = await store.fetchNote(noteId: noteId, workspaceId: workspaceId) {
            handleMissingNote(noteId: noteId, workspaceId: workspaceId)
        }
    }

    func handleMissingNote(noteId: String, workspaceId: String) {
        if case let .noteDetail(nId, wsId, _) = currentScreen,
           nId == noteId, wsId == workspaceId {
            currentScreen = .workspaceDetail(workspaceId: workspaceId)
            saveCurrentScreen()
        }
    }

    func onSettingsBack() {
        currentScreen = .workspaceList
    }

    func onOpenSettings() {
        if usesIPadShell, currentScreen.supportsConnectionLossOverlay {
            onSelectIPadSection(.settings)
            return
        }
        currentScreen = .settings
    }
}
