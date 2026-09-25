import Foundation
@testable import Intent
import Testing
import UIKit
import UserNotifications

// MARK: - Cross-session aggregation

/// NotificationManager stays a process-wide singleton but must alert for
/// every live backend session: backend sessions attach observers on their
/// own connections and events are tagged with the source `BackendID`
/// (window model v2: there is no default session to deduplicate against).
@Suite("NotificationManager cross-session aggregation", .serialized)
@MainActor
final class NotificationSessionAggregationTests {
    private static let activeConnectionId = UUID(uuid: (
        0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22,
        0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22
    ))

    /// Per-test isolated persistence (same pattern as
    /// BackendSessionRegistryTests) so AppCoordinator never touches the
    /// real app container.
    private let persistence: PersistenceManager
    private let suiteName: String

    init() throws {
        _ = TestKeychainStorage.installed
        suiteName = "NotificationManagerSessionAggregationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        persistence = PersistenceManager(
            defaults: defaults,
            keychainStorage: InMemoryKeychainStorage()
        )
    }

    deinit {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private func makeManager(
        defaultConnection: FakeConnectionManager,
        state: UIApplication.State = .active,
        windowEmitsFeedbackSound: Bool = false,
        feedback: @escaping () -> Void = {}
    ) -> (NotificationManager, NotificationManagerFakeCenter) {
        let center = NotificationManagerFakeCenter()
        let service = LocalNotificationService(center: center)
        let manager = NotificationManager(
            localNotificationService: service,
            applicationState: { state },
            activeConnectionId: { Self.activeConnectionId },
            presentFeedback: feedback,
            windowEmitsFeedbackSound: windowEmitsFeedbackSound,
            connection: defaultConnection,
            workspaceStore: WorkspaceStore(forTesting: true),
            registerEvents: false
        )
        return (manager, center)
    }

    private func makeSession(
        backendID: BackendID?,
        connection: SessionFakeConnectionManager,
        attentionCueCenter: WorkspaceAttentionCueCenter =
            WorkspaceAttentionCueCenter {}
    ) -> BackendSession {
        let workspaceStore = WorkspaceStore(forTesting: true)
        let fileLoader = WorkspaceFileImageLoader(connection: connection)
        return BackendSession(
            backendID: backendID,
            connection: connection,
            workspaceStore: workspaceStore,
            coordinatorFactory: { [persistence] claim in
                AppCoordinator(
                    workspaceStore: workspaceStore,
                    connection: connection,
                    persistence: persistence,
                    claimScreenRestoration: claim
                )
            },
            githubRepoStore: GitHubRepoStore(connectionManager: connection),
            creationOptionsStore: CreationOptionsStore(connectionManager: connection),
            prMonitorsStore: WorkspacePrMonitorsStore(connectionManager: connection),
            attachmentUploadService: AttachmentUploadService(connection: connection),
            workspaceFileImageLoader: fileLoader,
            attachmentImageLoader: AttachmentImageLoader(
                connection: connection,
                fileLoader: fileLoader
            ),
            attentionCueCenter: attentionCueCenter
        )
    }

    private func idleEventParams(agentId: String, workspaceId: String) -> [String: Any] {
        [
            "event": [
                "type": "agent:idle",
                "workspaceId": workspaceId,
                "data": ["agentId": agentId, "agentName": "Pinned Agent"]
            ] as [String: Any]
        ]
    }

    /// Poll (bounded) until the condition holds; fail at the call site on timeout.
    private func waitFor(
        _ description: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () -> Bool
    ) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(
            condition(),
            "Timed out waiting for \(description) after 200 polls at 10 ms intervals",
            sourceLocation: sourceLocation
        )
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
        let sessionHandlerCount = connection.eventHandlerCount

        manager.attachSessionObserver(for: session)
        manager.attachSessionObserver(for: session)
        #expect(
            connection.eventHandlerCount == sessionHandlerCount + 1,
            "Repeat attaches for the same backend must not stack handlers"
        )

        manager.detachSessionObserver(for: backendID)
        #expect(connection.eventHandlerCount == sessionHandlerCount)
        manager.detachSessionObserver(for: backendID)
        #expect(connection.eventHandlerCount == sessionHandlerCount)
    }

    @Test func attachingPairingSessionIsNoOp() {
        let (manager, _) = makeManager(defaultConnection: FakeConnectionManager())
        let connection = SessionFakeConnectionManager()
        let session = makeSession(backendID: nil, connection: connection)
        let sessionHandlerCount = connection.eventHandlerCount

        manager.attachSessionObserver(for: session)

        #expect(
            connection.eventHandlerCount == sessionHandlerCount,
            "A transient pairing session has no backend to observe"
        )
    }

    // MARK: - Backend-session alerts

    @Test func idleEventPresentsToastTaggedWithSourceBackend() async throws {
        let defaultFake = FakeConnectionManager()
        let (manager, center) = makeManager(defaultConnection: defaultFake, state: .active)
        let backendID = BackendID(UUID())
        let connection = SessionFakeConnectionManager()
        connection.responseMap["agent.list"] = ["agents": [[String: Any]]()]
        let session = makeSession(backendID: backendID, connection: connection)
        manager.attachSessionObserver(for: session)

        connection.deliverEvent(
            method: "event",
            params: idleEventParams(agentId: "agent-p", workspaceId: "ws-p")
        )
        try await waitFor("idle toast from the source backend") { manager.currentToast != nil }

        #expect(manager.currentToast?.agentId == "agent-p")
        #expect(manager.currentToast?.sourceBackendID == backendID)
        #expect(
            connection.didCallMethod("agent.list"),
            "The suppression read must go through the source session's connection"
        )
        #expect(!defaultFake.didCallMethod("agent.list"))
        #expect(center.requests.isEmpty)
    }

    @Test func idleEventInBackgroundPostsNotificationScopedToBackend() async throws {
        let (manager, center) = makeManager(
            defaultConnection: FakeConnectionManager(),
            state: .background
        )
        let backendID = BackendID(UUID())
        let connection = SessionFakeConnectionManager()
        connection.responseMap["agent.list"] = ["agents": [[String: Any]]()]
        let session = makeSession(backendID: backendID, connection: connection)
        manager.attachSessionObserver(for: session)

        connection.deliverEvent(
            method: "event",
            params: idleEventParams(agentId: "agent-p", workspaceId: "ws-p")
        )
        try await waitFor("background idle notification") { !center.requests.isEmpty }

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
            params: idleEventParams(agentId: "agent-p", workspaceId: "ws-p")
        )
        try await waitFor("idle toast from the last-used backend") { manager.currentToast != nil }

        #expect(
            connection.didCallMethod("agent.list"),
            "Every backend session is observed directly (v2: no default handler dedup)"
        )
        #expect(manager.currentToast?.sourceBackendID == backendID)
    }

    @Test func detachedSessionNoLongerAlerts() async {
        let (manager, center) = makeManager(defaultConnection: FakeConnectionManager())
        let backendID = BackendID(UUID())
        let connection = SessionFakeConnectionManager()
        connection.responseMap["agent.list"] = ["agents": [[String: Any]]()]
        let session = makeSession(backendID: backendID, connection: connection)
        manager.attachSessionObserver(for: session)
        manager.detachSessionObserver(for: backendID)

        connection.deliverEvent(
            method: "event",
            params: idleEventParams(agentId: "agent-p", workspaceId: "ws-p")
        )
        await drainMainQueue()

        #expect(manager.currentToast == nil)
        #expect(center.requests.isEmpty)
    }

    // MARK: - Alert-chime / attention-cue dedup (visionOS double chime)

    private func makeCueWorkspace(id: String, attention: String? = nil) -> Workspace {
        Workspace(
            id: id,
            title: "Test",
            branch: nil,
            baseRef: nil,
            status: nil,
            activity: nil,
            displayStatus: nil,
            attention: attention,
            lastActivity: nil,
            updatedAt: nil,
            repositoryOwner: nil,
            repositoryName: nil,
            prStatus: nil,
            prNumber: nil,
            diffSummaryTotalFiles: nil,
            taskStatsTotal: nil,
            taskStatsCompleted: nil,
            taskStatsInProgress: nil,
            agentSummaryCount: nil
        )
    }

    @Test func idleAlertChimeThenAttentionFlipYieldsOneAudibleTrigger() async throws {
        // agent:idle chimes via the observed session, then the same
        // completion flips the workspace to unread: the cue stays silent.
        let (manager, _) = makeManager(
            defaultConnection: FakeConnectionManager(),
            windowEmitsFeedbackSound: true
        )
        let backendID = BackendID(UUID())
        let connection = SessionFakeConnectionManager()
        connection.responseMap["agent.list"] = ["agents": [[String: Any]]()]
        let cueCenter = WorkspaceAttentionCueCenter(
            playSound: {},
            windowEmitsCueSound: true
        )
        let session = makeSession(
            backendID: backendID,
            connection: connection,
            attentionCueCenter: cueCenter
        )
        manager.attachSessionObserver(for: session)
        cueCenter.observe(workspaces: [makeCueWorkspace(id: "ws-p")])

        connection.deliverEvent(
            method: "event",
            params: idleEventParams(agentId: "agent-p", workspaceId: "ws-p")
        )
        try await waitFor("first idle-alert audible feedback") { manager.windowFeedbackEvent != nil }
        let feedbackEvent = try #require(
            manager.windowFeedbackEvent,
            "The first alert must request a chime before duplicate suppression is tested"
        )
        #expect(feedbackEvent.sourceBackendID == backendID)

        cueCenter.observe(workspaces: [makeCueWorkspace(id: "ws-p", attention: "unread")])
        #expect(
            cueCenter.windowCueEvent == nil,
            "The alert chime already sounded for ws-p — no second chime"
        )
    }

    @Test func attentionCueThenIdleAlertYieldsOneAudibleTrigger() async throws {
        // Reverse arrival order: the workspace snapshot flips first, then
        // the agent:idle alert arrives — the chime is suppressed.
        let (manager, _) = makeManager(
            defaultConnection: FakeConnectionManager(),
            windowEmitsFeedbackSound: true
        )
        let backendID = BackendID(UUID())
        let connection = SessionFakeConnectionManager()
        connection.responseMap["agent.list"] = ["agents": [[String: Any]]()]
        let cueCenter = WorkspaceAttentionCueCenter(
            playSound: {},
            windowEmitsCueSound: true
        )
        let session = makeSession(
            backendID: backendID,
            connection: connection,
            attentionCueCenter: cueCenter
        )
        manager.attachSessionObserver(for: session)
        cueCenter.observe(workspaces: [makeCueWorkspace(id: "ws-p")])
        cueCenter.observe(workspaces: [makeCueWorkspace(id: "ws-p", attention: "unread")])
        #expect(cueCenter.windowCueEvent != nil)

        connection.deliverEvent(
            method: "event",
            params: idleEventParams(agentId: "agent-p", workspaceId: "ws-p")
        )
        try await waitFor("idle toast after the attention cue") { manager.currentToast != nil }

        #expect(
            manager.windowFeedbackEvent == nil,
            "The attention cue already sounded for ws-p — no alert chime"
        )
        #expect(
            manager.currentToast != nil,
            "Dedup silences the sound only; the toast still shows"
        )
    }
}
