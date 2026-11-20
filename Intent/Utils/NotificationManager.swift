import Observation
import SwiftUI
import UserNotifications

struct ToastInfo: Equatable {
    let id: UUID
    let agentId: String
    let workspaceId: String
    let agentName: String
    let workspaceName: String
    let sourceBackendID: BackendID

    init(
        agentId: String,
        workspaceId: String,
        agentName: String,
        workspaceName: String,
        sourceBackendID: BackendID
    ) {
        self.id = UUID()
        self.agentId = agentId
        self.workspaceId = workspaceId
        self.agentName = agentName
        self.workspaceName = workspaceName
        self.sourceBackendID = sourceBackendID
    }
}

@MainActor
@Observable class NotificationManager {
    nonisolated static var platformWindowEmitsFeedbackSound: Bool {
        #if os(visionOS)
        true
        #else
        false
        #endif
    }

    static let shared = NotificationManager()

    var currentToast: ToastInfo?

    struct FeedbackEvent: Equatable {
        let id = UUID()
        let sourceBackendID: BackendID
    }

    struct PendingAgentSelection {
        let agentId: String
        let workspaceId: String
        let agentName: String
        let connectionId: UUID
    }

    var windowFeedbackEvent: FeedbackEvent?

    @ObservationIgnored var openAgentIds: [UUID: [String: Int]] = [:]

    @ObservationIgnored var openWorkspaceIds: [UUID: [String: Int]] = [:]

    @ObservationIgnored var dismissTask: Task<Void, Never>?
    @ObservationIgnored let localNotificationService: LocalNotificationService
    @ObservationIgnored let applicationState: () -> UIApplication.State
    @ObservationIgnored let presentFeedback: () -> Void
    @ObservationIgnored let relayDeliversAlerts: @MainActor (UUID) -> Bool
    @ObservationIgnored let windowEmitsFeedbackSound: Bool
    @ObservationIgnored let activeConnectionId: () -> UUID?
    @ObservationIgnored let connection: ConnectionManagerRouting
    @ObservationIgnored let workspaceStore: WorkspaceStore

    @ObservationIgnored var agentSelectionHandlers:
        [BackendID: (token: UUID, handler: (String, String, String, UUID) -> Void)] = [:]

    @ObservationIgnored var openBackendWindow: ((BackendID) -> Void)?

    @ObservationIgnored var supportsMultipleWindows = false

    @ObservationIgnored var pendingAgentSelection: PendingAgentSelection?

    @ObservationIgnored var observedSessions:
        [BackendID: (session: BackendSession, handlerId: UUID)] = [:]

    static func platformRelayDeliversAlerts(_ connectionId: UUID) -> Bool {
        #if os(iOS)
        PushRelayController.shared.deliversAlerts(for: connectionId)
        #else
        false
        #endif
    }

    init(
        localNotificationService: LocalNotificationService = .shared,
        applicationState: @escaping () -> UIApplication.State = {
            UIApplication.shared.applicationState
        },
        activeConnectionId: @escaping () -> UUID? = {
            PersistenceManager.shared.activeConnection()?.id
        },
        presentFeedback: @escaping () -> Void = {
            HapticManager.notification(.success)
        },
        windowEmitsFeedbackSound: Bool = NotificationManager.platformWindowEmitsFeedbackSound,
        relayDeliversAlerts: @escaping @MainActor (UUID) -> Bool = NotificationManager.platformRelayDeliversAlerts,
        connection: ConnectionManagerRouting = ConnectionManager.shared,
        workspaceStore: WorkspaceStore = WorkspaceStore.shared,
        registerEvents: Bool = true
    ) {
        self.localNotificationService = localNotificationService
        self.applicationState = applicationState
        self.activeConnectionId = activeConnectionId
        self.presentFeedback = presentFeedback
        self.windowEmitsFeedbackSound = windowEmitsFeedbackSound
        self.relayDeliversAlerts = relayDeliversAlerts
        self.connection = connection
        self.workspaceStore = workspaceStore
        localNotificationService.onWillPresentNotification = { [weak self] response in
            self?.handleForegroundNotification(response) ?? []
        }
        localNotificationService.onNotificationResponse = { [weak self] response in
            self?.handleNotificationResponse(response)
        }
        localNotificationService.requestAuthorizationIfNeeded()
        if registerEvents { registerEventHandler() }
    }
}

private extension NotificationManager {
    func handleForegroundNotification(
        _ response: LocalNotificationService.Response
    ) -> UNNotificationPresentationOptions {
        guard let agentId = response.agentId,
              let workspaceId = response.workspaceId,
              let agentName = response.agentName,
              let connectionId = response.connectionId
        else { return [] }
        guard canPresentForegroundAlert(connectionId: connectionId) else { return [] }
        if !response.foregroundPresentationHandled {
            presentForegroundAlert(
                agentId: agentId,
                workspaceId: workspaceId,
                agentName: agentName,
                workspaceName: nil,
                connectionId: connectionId
            )
        }
        return windowEmitsFeedbackSound ? [] : [.sound]
    }

    func registerEventHandler() {
        AppLog.notifications.debug("[NotificationManager] Registering event handler")
        connection.onEvent { [weak self] _, params in
            Task { @MainActor in
                self?.handleEvent(params, from: nil)
            }
        }
    }
}
