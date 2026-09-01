import SwiftUI
import Observation
import AudioToolbox

struct ToastInfo: Equatable {
    let id: UUID
    let agentId: String
    let workspaceId: String
    let agentName: String
    let workspaceName: String

    init(agentId: String, workspaceId: String, agentName: String, workspaceName: String) {
        self.id = UUID()
        self.agentId = agentId
        self.workspaceId = workspaceId
        self.agentName = agentName
        self.workspaceName = workspaceName
    }
}

@MainActor
@Observable class NotificationManager {
    static let shared = NotificationManager()

    var currentToast: ToastInfo?

    /// The agent ID currently being viewed in ConversationView
    var currentAgentId: String?

    /// The workspace ID currently being viewed (workspace detail or conversation)
    var currentWorkspaceId: String?

    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    private init() {
        registerEventHandler()
    }

    private func registerEventHandler() {
        AppLog.notifications.debug("[NotificationManager] Registering event handler")
        ConnectionManager.shared.onEvent { [weak self] method, params in
            Task { @MainActor in
                self?.handleEvent(params)
            }
        }
    }

    private func handleEvent(_ params: Any) {
        // Debug: log raw params type and keys
        AppLog.notifications.debug("[NotificationManager] handleEvent called, params type=\(type(of: params))")
        guard let dict = params as? [String: Any] else {
            AppLog.notifications.warning("[NotificationManager] ⚠️ params is not [String: Any], skipping")
            return
        }
        AppLog.notifications.debug("[NotificationManager] dict keys: \(dict.keys.sorted())")

        // Unwrap event from subscription wrapper
        let event: [String: Any]
        if let innerEvent = dict["event"] as? [String: Any] {
            event = innerEvent
            AppLog.notifications.debug("[NotificationManager] Unwrapped inner event, keys: \(event.keys.sorted())")
        } else {
            event = dict
            AppLog.notifications.debug("[NotificationManager] No inner event wrapper, using dict directly")
        }

        let eventType = event["type"] as? String
        AppLog.notifications.debug("[NotificationManager] Event type: \(eventType ?? "nil")")

        guard eventType == "agent:idle" else { return }

        guard let data = event["data"] as? [String: Any] else {
            AppLog.notifications.warning("[NotificationManager] ⚠️ agent:idle missing 'data' dict. Event keys: \(event.keys.sorted())")
            return
        }
        guard let agentId = data["agentId"] as? String else {
            AppLog.notifications.warning("[NotificationManager] ⚠️ agent:idle data missing 'agentId'. Data keys: \(data.keys.sorted())")
            return
        }
        guard let workspaceId = event["workspaceId"] as? String else {
            AppLog.notifications.warning("[NotificationManager] ⚠️ agent:idle missing 'workspaceId'. Event keys: \(event.keys.sorted())")
            return
        }

        // Emit-time fast paths: background agents and agents the payload
        // already marks as waiting on sub-agents never alert.
        AppLog.notifications.debug("[NotificationManager] agent:idle — agentId=\(agentId), currentAgentId=\(currentAgentId ?? "nil")")
        if Self.shouldSkipIdleEventFastPath(data) { return }

        let agentName = data["agentName"] as? String
            ?? event["actor"].flatMap { ($0 as? [String: Any])?["name"] as? String }
            ?? "Agent"

        // Fresh agent.list read (desktop parity): suppress when the idle agent
        // is still waiting on delegated sub-agents, another agent is active, or
        // the idle agent is background per metadata. Fail-open on read failure.
        Task { @MainActor [weak self] in
            let agents = await self?.fetchWorkspaceAgents(workspaceId: workspaceId)
            guard let self else { return }
            if Self.shouldSuppressIdleAlert(idleAgentId: agentId, agents: agents) {
                AppLog.notifications.debug("[NotificationManager] Suppressing idle alert — workspace still active or awaited")
                return
            }
            self.presentIdleAlert(agentId: agentId, workspaceId: workspaceId, agentName: agentName)
        }
    }

    /// Emit-time fast path over the raw `agent:idle` payload: skip background
    /// agents, and agents the daemon already marks as waiting on sub-agents.
    nonisolated static func shouldSkipIdleEventFastPath(_ data: [String: Any]) -> Bool {
        if data["isBackground"] as? Bool ?? false { return true }
        if data["isWaitingForOtherAgents"] as? Bool ?? false { return true }
        if let waitingIds = data["waitingForAgentIds"] as? [String], !waitingIds.isEmpty { return true }
        return false
    }

    /// Pure suppress-or-alert decision over a fresh `agent.list` read.
    /// `agents == nil` means the read failed — fail open (alert).
    ///
    /// The waiting-on-children gate is an iOS extension beyond the desktop
    /// port (desktop only honors the emit-time flag). It is safe because the
    /// list read can only under-suppress relative to the emit-time flag (a
    /// consumed watch clears the flag), and over-suppression self-heals: the
    /// awaited child's completion wakes the parent, whose next turn emits a
    /// fresh `agent:idle` with the flag cleared.
    ///
    /// The other-agents gate includes `isProcessing` in addition to desktop's
    /// `isStreaming || isResponding` — a deliberate divergence matching
    /// `AgentSession.isActive` semantics; do not "fix" it back in a parity sweep.
    nonisolated static func shouldSuppressIdleAlert(idleAgentId: String, agents: [AgentSession]?) -> Bool {
        guard let agents else { return false }
        if let idleAgent = agents.first(where: { $0.id == idleAgentId }) {
            if idleAgent.isBackground { return true }
            if idleAgent.isWaitingForOtherAgents || !idleAgent.waitingForAgentIds.isEmpty { return true }
        }
        return agents.contains { agent in
            agent.id != idleAgentId && (agent.isStreaming || agent.isResponding || agent.isProcessing)
        }
    }

    /// Fetches the workspace's agents for the suppression decision.
    /// Returns nil when the read fails or the response is malformed.
    private func fetchWorkspaceAgents(workspaceId: String) async -> [AgentSession]? {
        do {
            let result = try await ConnectionManager.shared.request(
                "agent.list",
                params: ["workspaceId": workspaceId]
            )
            if let dict = result as? [String: Any],
               let items = dict["agents"] as? [[String: Any]] {
                return items.compactMap { AgentSession.parseAgent($0) }
            }
            return nil
        } catch {
            AppLog.notifications.warning("[NotificationManager] agent.list failed, falling back to alert: \(error)")
            return nil
        }
    }

    private func presentIdleAlert(agentId: String, workspaceId: String, agentName: String) {
        // Look up workspace name
        let workspaceName = WorkspaceStore.shared.workspaces
            .first(where: { $0.id == workspaceId })?.title ?? "Workspace"

        if agentId == currentAgentId {
            // Currently viewing this exact agent's conversation — haptic + sound, no toast
            HapticManager.notification(.success)
            playSound()
        } else if workspaceId == currentWorkspaceId {
            // Viewing this workspace (agent list) — haptic + sound, no toast
            // The agent list will update via events, so the user will see the change
            HapticManager.notification(.success)
            playSound()
        } else {
            // Different workspace — haptic + sound + toast
            HapticManager.notification(.success)
            playSound()
            showToast(agentId: agentId, workspaceId: workspaceId,
                      agentName: agentName, workspaceName: workspaceName)
        }
    }

    private func playSound() {
        AudioServicesPlaySystemSound(1152) // "Bloom" — soft, pleasant completion chime
    }

    private func showToast(agentId: String, workspaceId: String,
                           agentName: String, workspaceName: String) {
        dismissTask?.cancel()

        withAnimation(.spring(
            response: Constants.Notification.presentationSpringResponse,
            dampingFraction: Constants.Notification.presentationSpringDamping
        )) {
            currentToast = ToastInfo(
                agentId: agentId, workspaceId: workspaceId,
                agentName: agentName, workspaceName: workspaceName)
        }

        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: Constants.Notification.displayDuration)
            guard !Task.isCancelled else { return }
            dismissToast()
        }
    }

    func dismissToast() {
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: Constants.Notification.dismissalAnimationDuration)) {
            currentToast = nil
        }
    }
}

