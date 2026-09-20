import AudioToolbox
import Observation
import SwiftUI
import UserNotifications

struct ToastInfo: Equatable {
    let id: UUID
    let agentId: String
    let workspaceId: String
    let agentName: String
    let workspaceName: String
    /// The backend the alert came from (window model v2: every alert has a
    /// concrete source connection, so taps can route to its window).
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
    private static let agentIdleFeedbackSoundID: SystemSoundID = 1152

    /// Platform default for `windowEmitsFeedbackSound` (see its doc).
    nonisolated static var platformWindowEmitsFeedbackSound: Bool {
        #if os(visionOS)
        true
        #else
        false
        #endif
    }

    static let shared = NotificationManager()

    var currentToast: ToastInfo?

    /// One feedback-sound request for a window to emit. On platforms where
    /// the window emits the sound (visionOS), the manager publishes this
    /// instead of playing a global sound, and the source backend's window
    /// plays it from within its own scene so spatial audio localizes it to
    /// that window. The fresh `id` distinguishes back-to-back requests from
    /// the same backend.
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

    /// The latest feedback request for a window to emit; observed by window
    /// roots (`WindowFeedbackSoundEmitter` via RootView). Never set on
    /// platforms that play global feedback.
    var windowFeedbackEvent: FeedbackEvent?

    /// Agent conversations currently on screen, keyed by their session's
    /// connection id. Counted (multiset): two windows on the same backend
    /// can show the same conversation, and closing one must not stop
    /// suppressing alerts for the surface still visible in the sibling.
    @ObservationIgnored var openAgentIds: [UUID: [String: Int]] = [:]

    /// Workspace details currently on screen, keyed by connection id.
    /// Counted for the same sibling-window reason as `openAgentIds`.
    @ObservationIgnored var openWorkspaceIds: [UUID: [String: Int]] = [:]

    @ObservationIgnored var dismissTask: Task<Void, Never>?
    @ObservationIgnored let localNotificationService: LocalNotificationService
    @ObservationIgnored let applicationState: () -> UIApplication.State
    @ObservationIgnored let presentFeedback: () -> Void
    /// Whether the source window's scene emits the feedback sound instead of
    /// `presentFeedback` playing a global one. True on visionOS, where the
    /// global system sound is non-spatial: emitting from the source window's
    /// own view hierarchy lets spatial audio tell the user which window's
    /// workspace finished. visionOS has no haptics (HapticManager no-ops),
    /// so routing the sound routes all of the feedback. Injectable because
    /// tests run on the iOS simulator.
    @ObservationIgnored let windowEmitsFeedbackSound: Bool
    @ObservationIgnored let activeConnectionId: () -> UUID?
    @ObservationIgnored let connection: ConnectionManagerRouting
    @ObservationIgnored let workspaceStore: WorkspaceStore

    /// Per-window agent-selection handlers, keyed by the window's bound
    /// backend (window model v2: no global last-window-wins handler). The
    /// registration token lets a disappearing window remove only its own
    /// registration, never a successor's.
    @ObservationIgnored var agentSelectionHandlers:
        [BackendID: (token: UUID, handler: (String, String, String, UUID) -> Void)] = [:]

    /// Opens — or raises — the window bound to a backend via
    /// `openWindow(value:)`. Set by window roots where multiple windows are
    /// supported.
    @ObservationIgnored var openBackendWindow: ((BackendID) -> Void)?

    /// Whether the platform supports multiple windows (visionOS, iPad). Set
    /// by window roots from `\.supportsMultipleWindows`.
    @ObservationIgnored var supportsMultipleWindows = false

    /// A tapped alert held until its source backend's window registers a
    /// handler (cold start, or a just-opened window still binding).
    @ObservationIgnored var pendingAgentSelection: PendingAgentSelection?

    /// Pinned sessions currently observed for cross-window alert aggregation,
    /// with the event-handler id registered on each session's connection.
    @ObservationIgnored var observedSessions:
        [BackendID: (session: BackendSession, handlerId: UUID)] = [:]

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
            AudioServicesPlaySystemSound(NotificationManager.agentIdleFeedbackSoundID)
        },
        windowEmitsFeedbackSound: Bool = NotificationManager.platformWindowEmitsFeedbackSound,
        connection: ConnectionManagerRouting = ConnectionManager.shared,
        workspaceStore: WorkspaceStore = WorkspaceStore.shared,
        registerEvents: Bool = true
    ) {
        self.localNotificationService = localNotificationService
        self.applicationState = applicationState
        self.activeConnectionId = activeConnectionId
        self.presentFeedback = presentFeedback
        self.windowEmitsFeedbackSound = windowEmitsFeedbackSound
        self.connection = connection
        self.workspaceStore = workspaceStore
        localNotificationService.onWillPresentNotification = { [weak self] response in
            self?.handleForegroundNotification(response)
        }
        localNotificationService.onNotificationResponse = { [weak self] response in
            self?.handleNotificationResponse(response)
        }
        localNotificationService.requestAuthorizationIfNeeded()
        if registerEvents { registerEventHandler() }
    }
}

private extension NotificationManager {
    func handleForegroundNotification(_ response: LocalNotificationService.Response) {
        guard let agentId = response.agentId,
              let workspaceId = response.workspaceId,
              let agentName = response.agentName,
              let connectionId = response.connectionId
        else { return }
        presentForegroundAlert(
            agentId: agentId,
            workspaceId: workspaceId,
            agentName: agentName,
            workspaceName: nil,
            connectionId: connectionId
        )
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
