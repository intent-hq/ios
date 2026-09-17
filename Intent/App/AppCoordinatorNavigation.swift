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
            guard let agentId = saved.agentId,
                  let workspaceId = saved.workspaceId,
                  let agentName = saved.agentName else { return false }
            markWorkspaceSeen(workspaceId)
            navigationState.suppressWorkspaceNavigation = true
            selectedWorkspaceId = workspaceId
            navigationState.suppressWorkspaceNavigation = false
            currentScreen = .agentConversation(
                agentId: agentId,
                workspaceId: workspaceId,
                agentName: agentName
            )
            Task { @MainActor in
                await self.validateRestoredAgent(agentId: agentId, workspaceId: workspaceId)
            }
            return true
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
        markWorkspaceSeen(workspaceId)
        selectedWorkspaceId = workspaceId
        currentScreen = .workspaceDetail(workspaceId: workspaceId)
        saveCurrentScreen()
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
    }

    func onBackToWorkspaceList() {
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
        navigationState.suppressWorkspaceNavigation = true
        selectedWorkspaceId = workspaceId
        navigationState.suppressWorkspaceNavigation = false
        conversationRequestId += 1
        currentScreen = .agentConversation(agentId: agentId, workspaceId: workspaceId, agentName: agentName)
        saveCurrentScreen()
    }

    func onSelectNote(_ noteId: String, workspaceId: String, noteTitle: String) {
        currentScreen = .noteDetail(noteId: noteId, workspaceId: workspaceId, noteTitle: noteTitle)
        saveCurrentScreen()
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
    private func validateRestoredAgent(agentId: String, workspaceId: String) async {
        do {
            let result = try await dependencies.connection.request(
                "agent.get",
                params: ["agentId": agentId, "workspaceId": workspaceId]
            )
            // A missing or malformed result is not a valid agent payload.
            if (result as? [String: Any]) == nil {
                handleMissingAgent(agentId: agentId, workspaceId: workspaceId)
            }
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
}
