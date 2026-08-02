import SwiftUI
import Combine

enum AppScreen {
    case loading
    case pairing
    case connecting
    case connectionFailed(error: String)
    case workspaceList
    case workspaceDetail(workspaceId: String)
    case agentConversation(agentId: String, workspaceId: String, agentName: String)
    case noteDetail(noteId: String, workspaceId: String, noteTitle: String)
    case settings
    case disconnected
}

@MainActor
class AppCoordinator: ObservableObject {
    @Published var currentScreen: AppScreen = .loading
    @Published var isDisconnected = false
    @Published var showCoverflow = false
    /// True when the pairing surface should also offer the remaining saved
    /// connections (e.g. after logging off the active connection while others
    /// are still saved). The Connect to… screen reads this flag.
    @Published var pairingShowsSavedConnections = false
    private var hasEverConnected = false
    /// Set to true to suppress didSet side effects on selectedWorkspaceId
    private var suppressWorkspaceNavigation = false

    @Published var selectedWorkspaceId: String? {
        didSet {
            if let workspaceId = selectedWorkspaceId, selectedWorkspaceId != oldValue, !suppressWorkspaceNavigation {
                currentScreen = .workspaceDetail(workspaceId: workspaceId)
            }
        }
    }

    var currentScreenDescription: String {
        String(describing: currentScreen)
    }
    private var connectionObserver: AnyCancellable?
    private var certMismatchObserver: AnyCancellable?
    private var workspaceValidationObserver: AnyCancellable?
    private var reconnectLoadingObserver: AnyCancellable?

    init() {
        startObservingConnection()
        startObservingCertMismatch()
        startObservingWorkspaceList()
    }

    private func startObservingConnection() {
        connectionObserver = ConnectionManager.shared.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .reconnecting, .disconnected:
                    if self.hasEverConnected {
                        self.isDisconnected = true
                    }
                case .connected:
                    let wasDisconnected = self.isDisconnected
                    self.hasEverConnected = true
                    if wasDisconnected {
                        // On reconnection, wait for workspace data to load before
                        // clearing the overlay so the UI doesn't flash blank metadata.
                        self.waitForWorkspaceLoadThenClearOverlay()
                    } else {
                        // Initial connection — isDisconnected was never true, nothing to clear.
                    }
                default:
                    break
                }
            }
    }

    /// Wait for WorkspaceStore to finish loading before clearing the reconnection overlay.
    /// Falls back to a 5-second timeout so the overlay never gets stuck.
    private func waitForWorkspaceLoadThenClearOverlay() {
        // Cancel any previous observer from a prior reconnection attempt
        reconnectLoadingObserver?.cancel()
        reconnectLoadingObserver = nil

        // If WorkspaceStore is not currently loading (fetchAll already completed
        // or hasn't started yet), check if data is already available.
        if !WorkspaceStore.shared.isLoading && WorkspaceStore.shared.lastUpdated != nil {
            self.isDisconnected = false
            return
        }

        // Observe isLoading: wait for it to go from true → false (fetchAll completed).
        reconnectLoadingObserver = WorkspaceStore.shared.$isLoading
            .dropFirst() // skip the current value
            .filter { !$0 } // wait for isLoading == false
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reconnectLoadingObserver = nil
                self?.isDisconnected = false
            }

        // Timeout: if the fetch takes too long or fails silently, clear the overlay anyway.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            guard let self = self else { return }
            if self.isDisconnected {
                self.reconnectLoadingObserver?.cancel()
                self.reconnectLoadingObserver = nil
                self.isDisconnected = false
            }
        }
    }


    private func startObservingCertMismatch() {
        certMismatchObserver = ConnectionManager.shared.$certMismatchDetected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mismatch in
                guard let self = self, mismatch else { return }
                self.currentScreen = .connectionFailed(error: "Server certificate has changed. Please re-pair your device.")
                // Reset the flag so it doesn't re-trigger
                ConnectionManager.shared.certMismatchDetected = false
            }
    }

    private func startObservingWorkspaceList() {
        workspaceValidationObserver = WorkspaceStore.shared.$workspaces
            .receive(on: DispatchQueue.main)
            .sink { [weak self] workspaces in
                guard let self = self else { return }
                // Only validate after workspaces have been fetched at least once
                guard WorkspaceStore.shared.lastUpdated != nil else { return }
                self.validateCurrentWorkspaceExists(in: workspaces)
            }
    }

    /// If the current screen references a workspace that no longer exists, navigate to workspace list.
    private func validateCurrentWorkspaceExists(in workspaces: [Workspace]) {
        let workspaceId: String?
        switch currentScreen {
        case .workspaceDetail(let id):
            workspaceId = id
        case .agentConversation(_, let id, _):
            workspaceId = id
        case .noteDetail(_, let id, _):
            workspaceId = id
        default:
            return
        }
        guard let wsId = workspaceId else { return }

        // Check if workspace exists at all
        guard let workspace = workspaces.first(where: { $0.id == wsId }) else {
            handleMissingWorkspace(workspaceId: wsId)
            return
        }

        // Check if workspace is archived or deleted
        let status = workspace.status?.lowercased() ?? ""
        if status == "archived" || status == "deleted" {
            handleMissingWorkspace(workspaceId: wsId)
        }
    }

    func onLoadComplete() {
        if PersistenceManager.shared.activeConnection() != nil {
            currentScreen = .connecting
        } else {
            currentScreen = .pairing
        }
    }

    func onConnectionSuccess() {
        // Try to restore last viewed screen
        if let saved = PersistenceManager.shared.loadLastScreen() {
            switch saved.screen {
            case "workspaceDetail":
                if let workspaceId = saved.workspaceId {
                    suppressWorkspaceNavigation = true
                    selectedWorkspaceId = workspaceId
                    suppressWorkspaceNavigation = false
                    currentScreen = .workspaceDetail(workspaceId: workspaceId)
                    return
                }
            case "conversation":
                if let agentId = saved.agentId,
                   let workspaceId = saved.workspaceId,
                   let agentName = saved.agentName {
                    suppressWorkspaceNavigation = true
                    selectedWorkspaceId = workspaceId
                    suppressWorkspaceNavigation = false
                    currentScreen = .agentConversation(
                        agentId: agentId, workspaceId: workspaceId, agentName: agentName)
                    // Validate agent still exists asynchronously
                    Task { @MainActor in
                        await self.validateRestoredAgent(agentId: agentId, workspaceId: workspaceId)
                    }
                    return
                }
            case "note":
                if let noteId = saved.noteId,
                   let workspaceId = saved.workspaceId,
                   let noteTitle = saved.noteTitle {
                    suppressWorkspaceNavigation = true
                    selectedWorkspaceId = workspaceId
                    suppressWorkspaceNavigation = false
                    currentScreen = .noteDetail(
                        noteId: noteId, workspaceId: workspaceId, noteTitle: noteTitle)
                    return
                }
            default:
                break
            }
        }
        currentScreen = .workspaceList
    }

    func onConnectionFailed(error: String) {
        currentScreen = .connectionFailed(error: error)
    }

    func onRetryConnection() {
        currentScreen = .connecting
    }

    func onReconnect() {
        currentScreen = .pairing
    }

    func onPaired() {
        pairingShowsSavedConnections = false
        currentScreen = .connecting
    }

    /// Drop the previous daemon's workspace data so no stale rows are shown
    /// after reconnecting, and so ConnectingView's waitForWorkspaceData
    /// (which polls lastUpdated == nil) genuinely waits for the new daemon.
    private func resetWorkspaceStore() {
        WorkspaceStore.shared.workspaces = []
        WorkspaceStore.shared.lastUpdated = nil
    }

    /// Switch to another saved connection: drop the live connection, clear the
    /// saved screen state, make the target connection active, and reconnect.
    func onSwitchConnection(id: UUID) {
        hasEverConnected = false
        isDisconnected = false
        ConnectionManager.shared.disconnect()
        resetWorkspaceStore()
        PersistenceManager.shared.clearLastScreen()
        PersistenceManager.shared.setActiveConnection(id: id)
        selectedWorkspaceId = nil
        pairingShowsSavedConnections = false
        currentScreen = .connecting
    }

    /// Delete a saved connection. Deleting the active one disconnects and routes
    /// like Log Off: pairing surface, with the remaining saved connections
    /// offered when any are left.
    func onDeleteConnection(id: UUID) {
        let wasActive = PersistenceManager.shared.activeConnection()?.id == id
        PersistenceManager.shared.deleteConnection(id: id)
        let hasRemaining = !PersistenceManager.shared.loadConnections().isEmpty
        if wasActive {
            hasEverConnected = false
            isDisconnected = false
            ConnectionManager.shared.disconnect()
            resetWorkspaceStore()
            PersistenceManager.shared.clearLastScreen()
            selectedWorkspaceId = nil
            pairingShowsSavedConnections = hasRemaining
            currentScreen = .pairing
        } else if !hasRemaining {
            pairingShowsSavedConnections = false
        }
    }

    func onOpenSettings() {
        currentScreen = .settings
    }

    /// Log Off forgets the active connection only. If other saved connections
    /// remain, the pairing surface is shown with those connections available;
    /// otherwise it behaves like first-run pairing.
    func onLogOff() {
        hasEverConnected = false
        isDisconnected = false
        ConnectionManager.shared.disconnect()
        resetWorkspaceStore()
        if let active = PersistenceManager.shared.activeConnection() {
            PersistenceManager.shared.deleteConnection(id: active.id)
        }
        PersistenceManager.shared.clearLastScreen()
        selectedWorkspaceId = nil
        pairingShowsSavedConnections = !PersistenceManager.shared.loadConnections().isEmpty
        currentScreen = .pairing
    }

    func onSelectWorkspace(_ workspaceId: String) {
        // Check for a saved per-workspace sub-screen and restore it
        if let saved = PersistenceManager.shared.loadWorkspaceScreen(workspaceId: workspaceId) {
            suppressWorkspaceNavigation = true
            selectedWorkspaceId = workspaceId
            suppressWorkspaceNavigation = false
            switch saved.screen {
            case "conversation":
                if let agentId = saved.agentId, let agentName = saved.agentName {
                    currentScreen = .agentConversation(
                        agentId: agentId, workspaceId: workspaceId, agentName: agentName)
                    saveCurrentScreen()
                    // Validate agent still exists asynchronously
                    Task { @MainActor in
                        await self.validateRestoredAgent(agentId: agentId, workspaceId: workspaceId)
                    }
                    return
                }
            case "note":
                if let noteId = saved.noteId, let noteTitle = saved.noteTitle {
                    currentScreen = .noteDetail(
                        noteId: noteId, workspaceId: workspaceId, noteTitle: noteTitle)
                    saveCurrentScreen()
                    return
                }
            default:
                break
            }
        }
        selectedWorkspaceId = workspaceId
        currentScreen = .workspaceDetail(workspaceId: workspaceId)
        saveCurrentScreen()
    }

    /// Called when a restored workspace is no longer found in the workspace list.
    /// Navigates back to the workspace list and clears all saved screen state for that workspace.
    func handleMissingWorkspace(workspaceId: String) {
        PersistenceManager.shared.clearWorkspaceScreen(workspaceId: workspaceId)
        PersistenceManager.shared.clearLastScreen()
        selectedWorkspaceId = nil
        currentScreen = .workspaceList
    }

    func onBackToWorkspaceList() {
        selectedWorkspaceId = nil
        currentScreen = .workspaceList
        PersistenceManager.shared.saveLastScreen(
            PersistenceManager.SavedScreen(
                screen: "workspaceList", workspaceId: nil,
                agentId: nil, agentName: nil, noteId: nil, noteTitle: nil))
    }

    func onSelectAgent(_ agentId: String, workspaceId: String, agentName: String) {
        suppressWorkspaceNavigation = true
        selectedWorkspaceId = workspaceId
        suppressWorkspaceNavigation = false
        currentScreen = .agentConversation(agentId: agentId, workspaceId: workspaceId, agentName: agentName)
        saveCurrentScreen()
        // Save per-workspace sub-screen
        PersistenceManager.shared.saveWorkspaceScreen(
            workspaceId: workspaceId,
            screen: PersistenceManager.SavedScreen(
                screen: "conversation", workspaceId: workspaceId,
                agentId: agentId, agentName: agentName, noteId: nil, noteTitle: nil))
    }

    func onSelectNote(_ noteId: String, workspaceId: String, noteTitle: String) {
        currentScreen = .noteDetail(noteId: noteId, workspaceId: workspaceId, noteTitle: noteTitle)
        saveCurrentScreen()
        // Save per-workspace sub-screen
        PersistenceManager.shared.saveWorkspaceScreen(
            workspaceId: workspaceId,
            screen: PersistenceManager.SavedScreen(
                screen: "note", workspaceId: workspaceId,
                agentId: nil, agentName: nil, noteId: noteId, noteTitle: noteTitle))
    }

    func onBackFromNote() {
        if let workspaceId = selectedWorkspaceId {
            currentScreen = .workspaceDetail(workspaceId: workspaceId)
            saveCurrentScreen()
            // Clear per-workspace sub-screen so re-entering the workspace shows the detail view.
            PersistenceManager.shared.clearWorkspaceScreen(workspaceId: workspaceId)
        }
    }

    func onBackToWorkspaceDetail() {
        if let workspaceId = selectedWorkspaceId {
            currentScreen = .workspaceDetail(workspaceId: workspaceId)
            saveCurrentScreen()
            // Clear per-workspace sub-screen so re-entering the workspace shows the detail view.
            PersistenceManager.shared.clearWorkspaceScreen(workspaceId: workspaceId)
        }
    }

    // MARK: - Screen Persistence

    private func saveCurrentScreen() {
        let saved: PersistenceManager.SavedScreen
        switch currentScreen {
        case .workspaceDetail(let workspaceId):
            saved = PersistenceManager.SavedScreen(
                screen: "workspaceDetail", workspaceId: workspaceId,
                agentId: nil, agentName: nil, noteId: nil, noteTitle: nil)
        case .agentConversation(let agentId, let workspaceId, let agentName):
            saved = PersistenceManager.SavedScreen(
                screen: "conversation", workspaceId: workspaceId,
                agentId: agentId, agentName: agentName, noteId: nil, noteTitle: nil)
        case .noteDetail(let noteId, let workspaceId, let noteTitle):
            saved = PersistenceManager.SavedScreen(
                screen: "note", workspaceId: workspaceId,
                agentId: nil, agentName: nil, noteId: noteId, noteTitle: noteTitle)
        default:
            return
        }
        PersistenceManager.shared.saveLastScreen(saved)
    }

    /// Validates that a restored agent still exists. If not, falls back to the workspace detail view.
    private func validateRestoredAgent(agentId: String, workspaceId: String) async {
        do {
            let result = try await ConnectionManager.shared.request(
                "agent.get",
                params: ["agentId": agentId, "workspaceId": workspaceId]
            )
            // If result is nil or doesn't contain agent data, the agent is gone
            if result == nil || (result as? [String: Any]) == nil {
                handleMissingAgent(workspaceId: workspaceId)
            }
        } catch {
            print("[AppCoordinator] Agent validation failed: \(error)")
            // Agent doesn't exist — fall back to workspace detail
            handleMissingAgent(workspaceId: workspaceId)
        }
    }

    /// Called when a restored agent is no longer found. Falls back to the workspace detail (agent list).
    private func handleMissingAgent(workspaceId: String) {
        // Only redirect if we're still on a conversation screen for this workspace
        if case .agentConversation(_, let wsId, _) = currentScreen, wsId == workspaceId {
            PersistenceManager.shared.clearWorkspaceScreen(workspaceId: workspaceId)
            currentScreen = .workspaceDetail(workspaceId: workspaceId)
            saveCurrentScreen()
        }
    }

    func onSettingsBack() {
        currentScreen = .workspaceList
    }
}

