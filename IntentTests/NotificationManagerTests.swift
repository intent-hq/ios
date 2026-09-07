import Foundation
import Testing
import UIKit
import UserNotifications
@testable import Intent

@MainActor
private final class NotificationManagerFakeCenter: LocalNotificationCenter {
    weak var delegate: (any UNUserNotificationCenterDelegate)?
    private(set) var requests: [UNNotificationRequest] = []
    private(set) var removedNotificationIdentifiers: [[String]] = []

    func getAuthorizationStatus(
        completionHandler: @escaping @MainActor @Sendable (UNAuthorizationStatus) -> Void
    ) {
        completionHandler(.authorized)
    }

    func requestAuthorization(
        options: UNAuthorizationOptions,
        completionHandler: @escaping @Sendable (Bool, (any Error)?) -> Void
    ) {
        completionHandler(true, nil)
    }

    func add(
        _ request: UNNotificationRequest,
        withCompletionHandler completionHandler: (@Sendable ((any Error)?) -> Void)?
    ) {
        requests.append(request)
        completionHandler?(nil)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedNotificationIdentifiers.append(identifiers)
    }
}

@Suite("NotificationManager idle-alert suppression")
@MainActor
struct NotificationManagerTests {
    private static let connectionId = UUID(
        uuidString: "11111111-1111-1111-1111-111111111111")!

    private func makeNotificationManager(
        state: UIApplication.State,
        feedback: @escaping () -> Void = {}
    ) -> (NotificationManager, NotificationManagerFakeCenter) {
        let center = NotificationManagerFakeCenter()
        let service = LocalNotificationService(center: center)
        let manager = NotificationManager(
            localNotificationService: service,
            applicationState: { state },
            activeConnectionId: { Self.connectionId },
            presentFeedback: feedback,
            registerEvents: false)
        return (manager, center)
    }

    private func makeAgent(
        id: String,
        status: String = "Idle",
        isBackground: Bool = false,
        isStreaming: Bool = false,
        isProcessing: Bool = false,
        isResponding: Bool = false,
        isWaitingForOtherAgents: Bool = false,
        waitingForAgentIds: [String] = []
    ) -> AgentSession {
        AgentSession(
            id: id, name: "Agent \(id)", status: status,
            isBackground: isBackground, isStreaming: isStreaming,
            isProcessing: isProcessing, isResponding: isResponding,
            isWaitingForOtherAgents: isWaitingForOtherAgents,
            waitingForAgentIds: waitingForAgentIds,
            createdAt: nil, updatedAt: nil, lastActivity: nil,
            lastAgentResponse: nil, lastUserMessage: nil,
            lastMessageRole: nil,
            digest: nil, specialist: nil, createdByAgentId: nil,
            attentionRequestKind: nil, attentionRequestReason: nil,
            attentionRequestTimestamp: nil
        )
    }

    // MARK: - shouldSuppressIdleAlert

    @Test func coordinatorWaitingOnChildrenSuppresses() {
        let agents = [makeAgent(id: "coord", isWaitingForOtherAgents: true, waitingForAgentIds: ["child"])]
        #expect(NotificationManager.shouldSuppressIdleAlert(idleAgentId: "coord", agents: agents) == true)
    }

    @Test func nonEmptyWaitingIdsAloneSuppresses() {
        let agents = [makeAgent(id: "coord", waitingForAgentIds: ["child"])]
        #expect(NotificationManager.shouldSuppressIdleAlert(idleAgentId: "coord", agents: agents) == true)
    }

    @Test func otherAgentStreamingSuppresses() {
        let agents = [makeAgent(id: "idle"), makeAgent(id: "other", isStreaming: true)]
        #expect(NotificationManager.shouldSuppressIdleAlert(idleAgentId: "idle", agents: agents) == true)
    }

    @Test func otherAgentRespondingSuppresses() {
        let agents = [makeAgent(id: "idle"), makeAgent(id: "other", isResponding: true)]
        #expect(NotificationManager.shouldSuppressIdleAlert(idleAgentId: "idle", agents: agents) == true)
    }

    @Test func otherAgentProcessingSuppresses() {
        let agents = [makeAgent(id: "idle"), makeAgent(id: "other", isProcessing: true)]
        #expect(NotificationManager.shouldSuppressIdleAlert(idleAgentId: "idle", agents: agents) == true)
    }

    @Test(arguments: ["active", "pending", "busy", "waiting"])
    func otherAgentStatusOnlyActivitySuppresses(status: String) {
        let agents = [makeAgent(id: "idle"), makeAgent(id: "other", status: status)]
        #expect(NotificationManager.shouldSuppressIdleAlert(idleAgentId: "idle", agents: agents))
    }

    @Test func idleAgentOwnActiveStatusDoesNotSuppress() {
        let agents = [makeAgent(id: "idle", status: "active")]
        #expect(!NotificationManager.shouldSuppressIdleAlert(idleAgentId: "idle", agents: agents))
    }

    @Test func idleAgentOwnActivityFlagsDoNotSuppress() {
        // Only OTHER agents' activity gates the alert — the idle agent's own
        // just-finished flags must not suppress its completion alert.
        let agents = [makeAgent(id: "idle", isStreaming: true, isResponding: true)]
        #expect(NotificationManager.shouldSuppressIdleAlert(idleAgentId: "idle", agents: agents) == false)
    }

    @Test func backgroundMetadataFallbackSuppresses() {
        let agents = [makeAgent(id: "bg", isBackground: true)]
        #expect(NotificationManager.shouldSuppressIdleAlert(idleAgentId: "bg", agents: agents) == true)
    }

    @Test func soleQuietAgentAlerts() {
        let agents = [makeAgent(id: "idle"), makeAgent(id: "other")]
        #expect(NotificationManager.shouldSuppressIdleAlert(idleAgentId: "idle", agents: agents) == false)
    }

    @Test func agentListFailureFailsOpen() {
        #expect(NotificationManager.shouldSuppressIdleAlert(idleAgentId: "idle", agents: nil) == false)
    }

    @Test func idleAgentMissingFromListAlertsWhenOthersQuiet() {
        let agents = [makeAgent(id: "other")]
        #expect(NotificationManager.shouldSuppressIdleAlert(idleAgentId: "gone", agents: agents) == false)
    }

    // MARK: - shouldSkipIdleEventFastPath

    @Test func backgroundEventFlagSkips() {
        #expect(NotificationManager.shouldSkipIdleEventFastPath(["isBackground": true]) == true)
    }

    @Test func waitingEventFlagSkips() {
        #expect(NotificationManager.shouldSkipIdleEventFastPath(["isWaitingForOtherAgents": true]) == true)
    }

    @Test func nonEmptyWaitingIdsOnEventSkips() {
        #expect(NotificationManager.shouldSkipIdleEventFastPath(["waitingForAgentIds": ["child"]]) == true)
    }

    @Test func emptyWaitingIdsOnEventDoesNotSkip() {
        #expect(NotificationManager.shouldSkipIdleEventFastPath(["waitingForAgentIds": [String]()]) == false)
    }

    @Test func plainIdleEventDoesNotSkip() {
        #expect(NotificationManager.shouldSkipIdleEventFastPath(["agentId": "a", "isBackground": false]) == false)
    }

    // MARK: - App-state presentation

    @Test @MainActor func inactiveAppPostsSystemNotificationWithoutFeedbackOrToast() {
        var feedbackCount = 0
        let (manager, center) = makeNotificationManager(state: .inactive) {
            feedbackCount += 1
        }
        manager.currentAgentId = "agent-1"
        manager.currentWorkspaceId = "workspace-1"

        manager.presentIdleAlert(
            agentId: "agent-1", workspaceId: "workspace-1", agentName: "Build Agent")

        #expect(center.requests.count == 1)
        #expect(feedbackCount == 0)
        #expect(manager.currentToast == nil)
    }

    @Test @MainActor func backgroundAppPostsSystemNotification() {
        let (manager, center) = makeNotificationManager(state: .background)

        manager.presentIdleAlert(
            agentId: "agent-1", workspaceId: "workspace-1", agentName: "Build Agent")

        #expect(center.requests.count == 1)
    }

    @Test @MainActor func activeAppKeepsFeedbackAndToastBehavior() {
        var feedbackCount = 0
        let (manager, center) = makeNotificationManager(state: .active) {
            feedbackCount += 1
        }

        manager.presentIdleAlert(
            agentId: "agent-1", workspaceId: "workspace-1", agentName: "Build Agent")

        #expect(center.requests.isEmpty)
        #expect(feedbackCount == 1)
        #expect(manager.currentToast?.agentId == "agent-1")
    }

    @Test @MainActor func activeAppStillSuppressesToastForOpenConversation() {
        var feedbackCount = 0
        let (manager, center) = makeNotificationManager(state: .active) {
            feedbackCount += 1
        }
        manager.currentAgentId = "agent-1"

        manager.presentIdleAlert(
            agentId: "agent-1", workspaceId: "workspace-1", agentName: "Build Agent")

        #expect(center.requests.isEmpty)
        #expect(feedbackCount == 1)
        #expect(manager.currentToast == nil)
    }

    @Test func foregroundDeliveryReplaysFeedbackAndToastBeforeSuppressingBanner() async {
        let center = NotificationManagerFakeCenter()
        let service = LocalNotificationService(center: center)
        var feedbackCount = 0
        let manager = NotificationManager(
            localNotificationService: service,
            applicationState: { .active },
            activeConnectionId: { Self.connectionId },
            presentFeedback: { feedbackCount += 1 },
            registerEvents: false)
        let response = LocalNotificationService.response(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: [
                "agentId": "agent-1",
                "workspaceId": "workspace-1",
                "agentName": "Build Agent",
                "connectionId": Self.connectionId.uuidString,
            ])

        let options = await withCheckedContinuation { continuation in
            service.deliverForegroundNotification(response) { options in
                continuation.resume(returning: options)
            }
        }

        #expect(options.isEmpty)
        #expect(feedbackCount == 1)
        #expect(manager.currentToast?.agentId == "agent-1")
    }

    // MARK: - Tap routing and delivered cleanup

    @Test @MainActor func notificationTapRoutesAfterColdStartHandlerInstallation() {
        let (manager, _) = makeNotificationManager(state: .inactive)
        let response = LocalNotificationService.response(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: [
                "agentId": "agent-1",
                "workspaceId": "workspace-1",
                "agentName": "Build Agent",
                "connectionId": Self.connectionId.uuidString,
            ])
        var routedValues: (String, String, String)?

        manager.handleNotificationResponse(response)
        manager.setAgentSelectionHandler { agentId, workspaceId, agentName, _ in
            routedValues = (agentId, workspaceId, agentName)
        }

        #expect(routedValues?.0 == "agent-1")
        #expect(routedValues?.1 == "workspace-1")
        #expect(routedValues?.2 == "Build Agent")
    }

    @Test @MainActor func notificationTapFromDifferentConnectionForwardsForWindowRouting() {
        // A non-active connectionId can only come from a pinned session's
        // notification: the tap is forwarded so the selection handler can
        // route it to that backend's window (tapRoute). On iPhone the
        // coordinator's window guard still drops it — same visible behavior
        // as the old manager-level filter.
        let (manager, _) = makeNotificationManager(state: .inactive)
        let otherConnectionId = UUID()
        let response = LocalNotificationService.response(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: [
                "agentId": "agent-1",
                "workspaceId": "workspace-1",
                "agentName": "Build Agent",
                "connectionId": otherConnectionId.uuidString,
            ])
        var routedConnectionId: UUID?
        manager.setAgentSelectionHandler { _, _, _, connectionId in
            routedConnectionId = connectionId
        }

        manager.handleNotificationResponse(response)

        #expect(routedConnectionId == otherConnectionId)
    }

    @Test @MainActor func notificationTapWithoutConnectionScopeIsIgnored() {
        let (manager, _) = makeNotificationManager(state: .inactive)
        let response = LocalNotificationService.response(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: [
                "agentId": "agent-1",
                "workspaceId": "workspace-1",
                "agentName": "Build Agent",
            ])
        var didRoute = false
        manager.setAgentSelectionHandler { _, _, _, _ in didRoute = true }

        manager.handleNotificationResponse(response)

        #expect(!didRoute)
    }

    @Test @MainActor func openingConversationClearsDeliveredAgentNotification() {
        let (manager, center) = makeNotificationManager(state: .active)

        manager.currentAgentId = "agent-1"

        #expect(center.removedNotificationIdentifiers == [[
            "agent-idle-\(Self.connectionId.uuidString)-agent-1"
        ]])
    }

    // MARK: - Multi-window tap routing (spec decision 5)

    private static let pinnedBackend = BackendID(UUID(
        uuidString: "22222222-2222-2222-2222-222222222222")!)

    @Test func tapWithoutMultiWindowSupportNavigatesInPlace() {
        #expect(NotificationManager.tapRoute(
            sourceBackendID: Self.pinnedBackend, windowBackendID: nil,
            supportsMultipleWindows: false) == .navigateInCurrentWindow)
    }

    @Test func defaultSessionTapNavigatesInPlace() {
        #expect(NotificationManager.tapRoute(
            sourceBackendID: nil, windowBackendID: nil,
            supportsMultipleWindows: true) == .navigateInCurrentWindow)
    }

    @Test func pinnedSourceTapOpensItsPinnedWindow() {
        #expect(NotificationManager.tapRoute(
            sourceBackendID: Self.pinnedBackend, windowBackendID: nil,
            supportsMultipleWindows: true)
            == .openPinnedWindow(Self.pinnedBackend))
    }

    @Test func pinnedSourceTapInAnotherPinnedWindowOpensTheSourceWindow() {
        #expect(NotificationManager.tapRoute(
            sourceBackendID: Self.pinnedBackend, windowBackendID: BackendID(UUID()),
            supportsMultipleWindows: true)
            == .openPinnedWindow(Self.pinnedBackend))
    }

    @Test func pinnedSourceTapInItsOwnWindowNavigatesInPlace() {
        #expect(NotificationManager.tapRoute(
            sourceBackendID: Self.pinnedBackend, windowBackendID: Self.pinnedBackend,
            supportsMultipleWindows: true) == .navigateInCurrentWindow)
    }

    @Test func activeConnectionNotificationHasNoSourceBackend() {
        let active = UUID()
        #expect(NotificationManager.sourceBackendID(
            connectionId: active, activeConnectionId: active) == nil)
    }

    @Test func nonActiveConnectionNotificationMapsToPinnedSource() {
        let pinned = UUID()
        #expect(NotificationManager.sourceBackendID(
            connectionId: pinned, activeConnectionId: UUID()) == BackendID(pinned))
        #expect(NotificationManager.sourceBackendID(
            connectionId: pinned, activeConnectionId: nil) == BackendID(pinned))
    }
}

// MARK: - Cross-session aggregation

/// NotificationManager stays a process-wide singleton but must alert for
/// every live backend session: backend sessions attach observers on their
/// own connections and events are tagged with the source `BackendID`
/// (window model v2: there is no default session to deduplicate against).
@Suite("NotificationManager cross-session aggregation", .serialized)
@MainActor
final class NotificationManagerSessionAggregationTests {
    private static let activeConnectionId = UUID(
        uuidString: "22222222-2222-2222-2222-222222222222")!

    /// Per-test isolated persistence (same pattern as
    /// BackendSessionRegistryTests) so AppCoordinator never touches the
    /// real app container.
    private let persistence: PersistenceManager
    private let suiteName: String

    init() {
        _ = TestKeychainStorage.installed
        suiteName = "NotificationManagerSessionAggregationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        persistence = PersistenceManager(
            defaults: defaults, keychainStorage: InMemoryKeychainStorage())
    }

    deinit {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private func makeManager(
        state: UIApplication.State = .active,
        defaultConnection: FakeConnectionManager
    ) -> (NotificationManager, NotificationManagerFakeCenter) {
        let center = NotificationManagerFakeCenter()
        let service = LocalNotificationService(center: center)
        let manager = NotificationManager(
            localNotificationService: service,
            applicationState: { state },
            activeConnectionId: { Self.activeConnectionId },
            presentFeedback: {},
            connection: defaultConnection,
            workspaceStore: WorkspaceStore(forTesting: true),
            registerEvents: false)
        return (manager, center)
    }

    private func makeSession(
        backendID: BackendID?, connection: SessionFakeConnectionManager
    ) -> BackendSession {
        let workspaceStore = WorkspaceStore(forTesting: true)
        let fileLoader = WorkspaceFileImageLoader(connection: connection)
        return BackendSession(
            backendID: backendID,
            connection: connection,
            workspaceStore: workspaceStore,
            coordinatorFactory: { [persistence] claim in
                AppCoordinator(
                    workspaceStore: workspaceStore, connection: connection,
                    persistence: persistence, claimScreenRestoration: claim)
            },
            prMonitorsStore: WorkspacePrMonitorsStore(connectionManager: connection),
            attachmentUploadService: AttachmentUploadService(connection: connection),
            workspaceFileImageLoader: fileLoader,
            attachmentImageLoader: AttachmentImageLoader(
                connection: connection, fileLoader: fileLoader),
            attentionCueCenter: WorkspaceAttentionCueCenter(playSound: {}))
    }

    private func idleEventParams(agentId: String, workspaceId: String) -> [String: Any] {
        [
            "event": [
                "type": "agent:idle",
                "workspaceId": workspaceId,
                "data": ["agentId": agentId, "agentName": "Pinned Agent"],
            ] as [String: Any]
        ]
    }

    /// Poll (bounded) until the condition holds.
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Drain the MainActor queue so spawned handler Tasks have run before
    /// negative assertions.
    private func drainMainQueue() async {
        for _ in 0..<20 { await Task.yield() }
    }

    // MARK: - Observer lifecycle

    @Test func attachRegistersOneHandlerAndDetachRemovesIt() {
        let (manager, _) = makeManager(defaultConnection: FakeConnectionManager())
        let backendID = BackendID(UUID())
        let connection = SessionFakeConnectionManager()
        let session = makeSession(backendID: backendID, connection: connection)

        manager.attachSessionObserver(for: session)
        manager.attachSessionObserver(for: session)
        #expect(connection.eventHandlerCount == 1,
                "Repeat attaches for the same backend must not stack handlers")

        manager.detachSessionObserver(for: backendID)
        #expect(connection.eventHandlerCount == 0)
        manager.detachSessionObserver(for: backendID)
        #expect(connection.eventHandlerCount == 0)
    }

    @Test func attachingPairingSessionIsNoOp() {
        let (manager, _) = makeManager(defaultConnection: FakeConnectionManager())
        let connection = SessionFakeConnectionManager()
        let session = makeSession(backendID: nil, connection: connection)

        manager.attachSessionObserver(for: session)

        #expect(connection.eventHandlerCount == 0,
                "A transient pairing session has no backend to observe")
    }

    // MARK: - Backend-session alerts

    @Test func idleEventPresentsToastTaggedWithSourceBackend() async throws {
        let defaultFake = FakeConnectionManager()
        let (manager, center) = makeManager(state: .active, defaultConnection: defaultFake)
        let backendID = BackendID(UUID())
        let connection = SessionFakeConnectionManager()
        connection.responseMap["agent.list"] = ["agents": [[String: Any]]()]
        let session = makeSession(backendID: backendID, connection: connection)
        manager.attachSessionObserver(for: session)

        connection.deliverEvent(
            method: "event",
            params: idleEventParams(agentId: "agent-p", workspaceId: "ws-p"))
        try await waitFor { manager.currentToast != nil }

        #expect(manager.currentToast?.agentId == "agent-p")
        #expect(manager.currentToast?.sourceBackendID == backendID)
        #expect(connection.didCallMethod("agent.list"),
                "The suppression read must go through the source session's connection")
        #expect(!defaultFake.didCallMethod("agent.list"))
        #expect(center.requests.isEmpty)
    }

    @Test func idleEventInBackgroundPostsNotificationScopedToBackend() async throws {
        let (manager, center) = makeManager(
            state: .background, defaultConnection: FakeConnectionManager())
        let backendID = BackendID(UUID())
        let connection = SessionFakeConnectionManager()
        connection.responseMap["agent.list"] = ["agents": [[String: Any]]()]
        let session = makeSession(backendID: backendID, connection: connection)
        manager.attachSessionObserver(for: session)

        connection.deliverEvent(
            method: "event",
            params: idleEventParams(agentId: "agent-p", workspaceId: "ws-p"))
        try await waitFor { !center.requests.isEmpty }

        #expect(center.requests.map(\.identifier) == [
            "agent-idle-\(backendID.connectionID.uuidString)-agent-p"
        ])
        #expect(manager.currentToast == nil)
    }

    @Test func sessionOnLastUsedBackendStillAlerts() async throws {
        let (manager, _) = makeManager(defaultConnection: FakeConnectionManager())
        let backendID = BackendID(Self.activeConnectionId)
        let connection = SessionFakeConnectionManager()
        connection.responseMap["agent.list"] = ["agents": [[String: Any]]()]
        let session = makeSession(backendID: backendID, connection: connection)
        manager.attachSessionObserver(for: session)

        connection.deliverEvent(
            method: "event",
            params: idleEventParams(agentId: "agent-p", workspaceId: "ws-p"))
        try await waitFor { manager.currentToast != nil }

        #expect(connection.didCallMethod("agent.list"),
                "Every backend session is observed directly (v2: no default handler dedup)")
        #expect(manager.currentToast?.sourceBackendID == backendID)
    }

    @Test func detachedSessionNoLongerAlerts() async throws {
        let (manager, center) = makeManager(defaultConnection: FakeConnectionManager())
        let backendID = BackendID(UUID())
        let connection = SessionFakeConnectionManager()
        connection.responseMap["agent.list"] = ["agents": [[String: Any]]()]
        let session = makeSession(backendID: backendID, connection: connection)
        manager.attachSessionObserver(for: session)
        manager.detachSessionObserver(for: backendID)

        connection.deliverEvent(
            method: "event",
            params: idleEventParams(agentId: "agent-p", workspaceId: "ws-p"))
        await drainMainQueue()

        #expect(manager.currentToast == nil)
        #expect(center.requests.isEmpty)
    }
}
