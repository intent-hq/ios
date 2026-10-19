import Foundation
import SwiftUI

extension NotificationManager {
    // MARK: - Window visibility (connection-scoped)

    /// A conversation became visible in some window: suppress its toasts
    /// and clear any delivered system notification for the same agent on
    /// the same backend — never another backend's same-id agent.
    func conversationOpened(agentId: String, connectionId: UUID) {
        openAgentIds[connectionId, default: [:]][agentId, default: 0] += 1
        localNotificationService.removeDeliveredNotifications(
            forAgentId: agentId,
            connectionId: connectionId
        )
    }

    /// Balances `conversationOpened`. Keyed by (agent, connection), so a
    /// parent conversation's disappear never clobbers a pushed child's —
    /// or another window's — visibility.
    func conversationClosed(agentId: String, connectionId: UUID) {
        decrement(&openAgentIds, id: agentId, connectionId: connectionId)
    }

    /// A workspace detail became visible in some window.
    func workspaceOpened(workspaceId: String, connectionId: UUID) {
        openWorkspaceIds[connectionId, default: [:]][workspaceId, default: 0] += 1
    }

    /// Balances `workspaceOpened`.
    func workspaceClosed(workspaceId: String, connectionId: UUID) {
        decrement(&openWorkspaceIds, id: workspaceId, connectionId: connectionId)
    }

    private func decrement(
        _ counts: inout [UUID: [String: Int]],
        id: String,
        connectionId: UUID
    ) {
        guard let count = counts[connectionId]?[id] else { return }
        counts[connectionId]?[id] = count > 1 ? count - 1 : nil
    }

    private func isAgentOpen(_ agentId: String, connectionId: UUID) -> Bool {
        (openAgentIds[connectionId]?[agentId] ?? 0) > 0
    }

    private func isWorkspaceOpen(_ workspaceId: String, connectionId: UUID) -> Bool {
        (openWorkspaceIds[connectionId]?[workspaceId] ?? 0) > 0
    }

    // MARK: - Alert presentation

    func presentIdleAlert(agentId: String, workspaceId: String, agentName: String) {
        guard let connectionId = activeConnectionId() else { return }
        presentIdleAlert(
            agentId: agentId,
            workspaceId: workspaceId,
            agentName: agentName,
            connectionId: connectionId,
            sourceBackendID: nil
        )
    }

    func presentIdleAlert(
        agentId: String,
        workspaceId: String,
        agentName: String,
        connectionId: UUID,
        sourceBackendID: BackendID?
    ) {
        guard sourceStillCurrent(sourceBackendID, connectionId: connectionId) else { return }
        // Look up workspace name in the source session's store
        let workspaceName = workspaceStore(for: sourceBackendID).workspaces
            .first { $0.id == workspaceId }?.title ?? "Workspace"

        let isForeground = applicationState() == .active
        if isForeground {
            guard presentForegroundAlert(
                agentId: agentId,
                workspaceId: workspaceId,
                agentName: agentName,
                workspaceName: workspaceName,
                connectionId: connectionId
            ) else { return }
            guard !windowEmitsFeedbackSound else { return }
        }

        // iOS owns sound policy; the toast does not depend on notification permission.
        localNotificationService.postAgentIdleNotification(
            agentId: agentId,
            workspaceId: workspaceId,
            agentName: agentName,
            workspaceName: workspaceName,
            connectionId: connectionId,
            foregroundPresentationHandled: isForeground
        )
    }

    // Suppression is connection-scoped (window model v2): only the SAME
    // backend's open conversation/workspace downgrades its alert to
    // feedback — an identically-named id open on another backend's window
    // still toasts. The toast is tagged with the concrete source backend
    // (`workspaceStore(for:)` falls back to the default store when the
    // source isn't an observed session — the legacy handler path).
    // Presentation is window-scoped: on multi-window platforms the alert
    // (feedback and toast alike) presents only via the source backend's
    // window (`alertPresents`); other windows see and hear nothing.
    @discardableResult
    func presentForegroundAlert(
        agentId: String,
        workspaceId: String,
        agentName: String,
        workspaceName: String?,
        connectionId: UUID
    ) -> Bool {
        let sourceBackendID = BackendID(connectionId)
        guard canPresentForegroundAlert(connectionId: connectionId) else { return false }
        let workspaceName = workspaceName ?? workspaceStore(for: sourceBackendID).workspaces
            .first { $0.id == workspaceId }?.title ?? "Workspace"
        if isAgentOpen(agentId, connectionId: connectionId) {
            // Currently viewing this exact agent's conversation — feedback, no toast
            playFeedback(source: sourceBackendID, workspaceId: workspaceId)
        } else if isWorkspaceOpen(workspaceId, connectionId: connectionId) {
            // Viewing this workspace (agent list) — feedback, no toast
            // The agent list will update via events, so the user will see the change
            playFeedback(source: sourceBackendID, workspaceId: workspaceId)
        } else {
            // Different workspace — feedback + toast
            playFeedback(source: sourceBackendID, workspaceId: workspaceId)
            showToast(
                agentId: agentId,
                workspaceId: workspaceId,
                agentName: agentName,
                workspaceName: workspaceName,
                sourceBackendID: sourceBackendID
            )
        }
        return true
    }

    func canPresentForegroundAlert(connectionId: UUID) -> Bool {
        Self.alertPresents(
            source: BackendID(connectionId),
            registeredBackends: Set(agentSelectionHandlers.keys),
            supportsMultipleWindows: supportsMultipleWindows
        )
    }

    /// Plays alert feedback: on window-emitting platforms (visionOS) publish
    /// the request for the source backend's window to emit the chime from
    /// its own scene (`WindowFeedbackSoundEmitter`); elsewhere play the
    /// haptic feedback. iOS sound goes through local notifications.
    /// Deduplicated against the source session's workspace attention cue:
    /// one agent event (idle/blocker) often also
    /// flips its workspace's attention, and both sounds within a second is
    /// the "double chime" — the cue center arbitrates so at most one
    /// audible trigger plays per workspace per event (no-op off visionOS,
    /// where the cue center never sounds).
    private func playFeedback(source: BackendID, workspaceId: String) {
        if let cueCenter = observedSessions[source]?.session.attentionCueCenter,
           !cueCenter.noteAlertChimeWillPlay(workspaceId: workspaceId) {
            return
        }
        if windowEmitsFeedbackSound {
            windowFeedbackEvent = FeedbackEvent(sourceBackendID: source)
        } else {
            presentFeedback()
        }
    }

    private func showToast(
        agentId: String,
        workspaceId: String,
        agentName: String,
        workspaceName: String,
        sourceBackendID: BackendID
    ) {
        dismissTask?.cancel()

        withAnimation(.spring(
            response: Constants.Notification.presentationSpringResponse,
            dampingFraction: Constants.Notification.presentationSpringDamping
        )) {
            currentToast = ToastInfo(
                agentId: agentId,
                workspaceId: workspaceId,
                agentName: agentName,
                workspaceName: workspaceName,
                sourceBackendID: sourceBackendID
            )
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
