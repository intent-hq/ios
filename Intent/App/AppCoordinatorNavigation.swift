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
    /// Cleared by navigation, even when the user later returns to the same overview.
    var recentWorkspaceAgentRequestId: UUID?
}

extension AppCoordinator {
    /// Whether this coordinator owns the session's last-screen persistence.
    /// Only the first window per backend session restores and saves that
    /// backend's screen; duplicated windows start at the workspace list.
    /// The claim is consumed lazily on first use so coordinators built for
    /// discarded SwiftUI view constructions never spend it.
    private var restoresLastScreen: Bool {
        if case let .resolved(claimed) = navigationState.claimedScreenRestoration { return claimed }
        let claimed = dependencies.claimScreenRestoration()
        navigationState.claimedScreenRestoration = .resolved(claimed)
        return claimed
    }

    func restoreLastScreenIfAvailable() -> Bool {
        // Restoring into a workspace counts as viewing it, mirroring the FE.
        // Only the session's first window restores; other windows show the list.
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

    /// After a reconnect, re-run agent validation if the current screen is a conversation.
    func revalidateCurrentAgentAfterReconnect() {
        if case let .agentConversation(agentId, workspaceId, _) = currentScreen {
            Task { @MainActor in
                await self.validateRestoredAgent(agentId: agentId, workspaceId: workspaceId)
            }
        }
    }

    /// An explicit workspace tap always lands on the workspace overview
    /// (ios#349). Saved sub-screens are only restored by cold-start restore
    /// (`restoreLastScreenIfAvailable`); explicit agent/note selection and
    /// notification routing go through `onSelectAgent` / `onSelectNote`.
    func onSelectWorkspace(_ workspaceId: String) {
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

    /// A completed row swipe opens the overview first, then the most recently
    /// active non-retired agent. Ordinary row taps keep using onSelectWorkspace.
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
                // Unscoped reads include delegated and background agents too.
                // Every page is read: the newest agents are on the last one.
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
                // A newer swipe or navigation superseded this lookup.
            } catch {
                AppLog.app.error("[AppCoordinator] Recent workspace agent lookup failed: \(error)")
            }
        }
    }

    /// The swipe's lookup still owns navigation: no newer swipe, and the user
    /// is still on that workspace's overview.
    private func recentAgentLookupIsCurrent(_ requestId: UUID, workspaceId: String) -> Bool {
        guard !Task.isCancelled, navigationState.recentWorkspaceAgentRequestId == requestId,
              selectedSection == .workspaces,
              case let .workspaceDetail(currentWorkspaceId) = currentScreen else { return false }
        return currentWorkspaceId == workspaceId
    }

    /// Fire-and-forget workspace.markSeen: clears the server-owned unread
    /// attention flag (blue dot) across clients when the user opens a
    /// workspace, mirroring the FE. Failures are logged and ignored — an
    /// older daemon without the method just keeps its legacy behavior.
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

    /// Called when a restored workspace is no longer found in the workspace list.
    /// Navigates back to the workspace list and clears the saved screen state.
    func handleMissingWorkspace() {
        if let connectionID = windowConnectionID {
            dependencies.persistence.clearLastScreen(for: connectionID)
        }
        selectedWorkspaceId = nil
        currentScreen = .workspaceList
        ensureIPadWorkspaceSelection()
        if usesIPadShell, iPadNavigation.section == .workspaces,
           case .workspaceList = currentScreen {
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

    // MARK: - Screen Persistence

    private func saveCurrentScreen() {
        // Windows without the restoration claim must not overwrite the
        // restoring window's saved navigation (spec decision 1b).
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

    /// Validates that a restored agent still exists. Only a definitive not-found falls back —
    /// transient/transport errors leave the screen in place (the conversation load re-validates).
    func validateRestoredAgent(agentId: String, workspaceId: String) async {
        do {
            _ = try await agentDetails.load(agentId: agentId, workspaceId: workspaceId)
        } catch is AgentDetailError {
            handleMissingAgent(agentId: agentId, workspaceId: workspaceId)
        } catch {
            AppLog.app.error("[AppCoordinator] Agent validation failed: \(error)")
            // Only a definitive not-found (-32602 with data.code == "not-found",
            // PROTOCOL §3.3/§9) reads as deletion.
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

    /// Called when the agent being viewed is no longer found (restore validation,
    /// not-found at conversation load, or deletion while open).
    /// Falls back to the workspace detail (agent list).
    func handleMissingAgent(agentId: String, workspaceId: String) {
        // Only redirect if we're still viewing this agent's conversation — a stale
        // validation must not evict a different conversation in the same workspace.
        if case let .agentConversation(aId, wsId, _) = currentScreen,
           aId == agentId, wsId == workspaceId {
            currentScreen = .workspaceDetail(workspaceId: workspaceId)
            saveCurrentScreen()
        }
    }

    /// Validates that a restored note still exists. Only a definitive not-found falls back —
    /// transient/transport errors leave the screen in place.
    func validateRestoredNote(noteId: String, workspaceId: String, noteStore: NoteStore? = nil) async {
        let store = noteStore ?? NoteStore(connectionManager: dependencies.connection)
        if case .notFound = await store.fetchNote(noteId: noteId, workspaceId: workspaceId) {
            handleMissingNote(noteId: noteId, workspaceId: workspaceId)
        }
    }

    /// Called when the note being viewed no longer exists. Falls back to the workspace detail view.
    func handleMissingNote(noteId: String, workspaceId: String) {
        // Only redirect if we're still viewing this note — a stale validation
        // must not evict a different note screen in the same workspace.
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
