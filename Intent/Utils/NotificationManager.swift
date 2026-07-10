import SwiftUI
import Combine
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
class NotificationManager: ObservableObject {
    static let shared = NotificationManager()

    @Published var currentToast: ToastInfo?

    /// The agent ID currently being viewed in ConversationView
    var currentAgentId: String?

    /// The workspace ID currently being viewed (workspace detail or conversation)
    var currentWorkspaceId: String?

    private var dismissTask: Task<Void, Never>?

    private init() {
        registerEventHandler()
    }

    private func registerEventHandler() {
        print("[NotificationManager] Registering event handler")
        ConnectionManager.shared.onEvent { [weak self] method, params in
            Task { @MainActor in
                self?.handleEvent(params)
            }
        }
    }

    private func handleEvent(_ params: Any) {
        // Debug: log raw params type and keys
        print("[NotificationManager] handleEvent called, params type=\(type(of: params))")
        guard let dict = params as? [String: Any] else {
            print("[NotificationManager] ⚠️ params is not [String: Any], skipping")
            return
        }
        print("[NotificationManager] dict keys: \(dict.keys.sorted())")

        // Unwrap event from subscription wrapper
        let event: [String: Any]
        if let innerEvent = dict["event"] as? [String: Any] {
            event = innerEvent
            print("[NotificationManager] Unwrapped inner event, keys: \(event.keys.sorted())")
        } else {
            event = dict
            print("[NotificationManager] No inner event wrapper, using dict directly")
        }

        let eventType = event["type"] as? String
        print("[NotificationManager] Event type: \(eventType ?? "nil")")

        guard eventType == "agent:idle" else { return }

        guard let data = event["data"] as? [String: Any] else {
            print("[NotificationManager] ⚠️ agent:idle missing 'data' dict. Event keys: \(event.keys.sorted())")
            return
        }
        guard let agentId = data["agentId"] as? String else {
            print("[NotificationManager] ⚠️ agent:idle data missing 'agentId'. Data keys: \(data.keys.sorted())")
            return
        }
        guard let workspaceId = event["workspaceId"] as? String else {
            print("[NotificationManager] ⚠️ agent:idle missing 'workspaceId'. Event keys: \(event.keys.sorted())")
            return
        }

        // Check if background agent — skip entirely
        let isBackground = data["isBackground"] as? Bool ?? false
        print("[NotificationManager] agent:idle — agentId=\(agentId), isBackground=\(isBackground), currentAgentId=\(currentAgentId ?? "nil")")
        if isBackground { return }

        // Check if agent is waiting on sub-agents — skip notification
        let isWaitingForAgents = data["isWaitingForAgents"] as? Bool ?? false
        if isWaitingForAgents { return }

        let agentName = data["agentName"] as? String
            ?? event["actor"].flatMap { ($0 as? [String: Any])?["name"] as? String }
            ?? "Agent"

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

        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            currentToast = ToastInfo(
                agentId: agentId, workspaceId: workspaceId,
                agentName: agentName, workspaceName: workspaceName)
        }

        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000) // 4 seconds
            guard !Task.isCancelled else { return }
            dismissToast()
        }
    }

    func dismissToast() {
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.25)) {
            currentToast = nil
        }
    }
}

