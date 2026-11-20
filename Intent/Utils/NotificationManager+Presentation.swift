import Foundation
import SwiftUI

extension NotificationManager {
    func conversationOpened(agentId: String, connectionId: UUID) {
        openAgentIds[connectionId, default: [:]][agentId, default: 0] += 1
        localNotificationService.removeDeliveredNotifications(
            forAgentId: agentId,
            connectionId: connectionId
        )
    }

    func conversationClosed(agentId: String, connectionId: UUID) {
        decrement(&openAgentIds, id: agentId, connectionId: connectionId)
    }

    func workspaceOpened(workspaceId: String, connectionId: UUID) {
        openWorkspaceIds[connectionId, default: [:]][workspaceId, default: 0] += 1
    }

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
        guard !relayDeliversAlerts(connectionId) else { return }
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

        localNotificationService.postAgentIdleNotification(
            agentId: agentId,
            workspaceId: workspaceId,
            agentName: agentName,
            workspaceName: workspaceName,
            connectionId: connectionId,
            foregroundPresentationHandled: isForeground
        )
    }

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
            playFeedback(source: sourceBackendID, workspaceId: workspaceId)
        } else if isWorkspaceOpen(workspaceId, connectionId: connectionId) {
            playFeedback(source: sourceBackendID, workspaceId: workspaceId)
        } else {
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
