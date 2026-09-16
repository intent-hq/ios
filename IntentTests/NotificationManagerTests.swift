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
        windowEmitsFeedbackSound: Bool = false,
        feedback: @escaping () -> Void = {}
    ) -> (NotificationManager, NotificationManagerFakeCenter) {
        let center = NotificationManagerFakeCenter()
        let service = LocalNotificationService(center: center)
        let manager = NotificationManager(
            localNotificationService: service,
            applicationState: { state },
            activeConnectionId: { Self.connectionId },
            presentFeedback: feedback,
            windowEmitsFeedbackSound: windowEmitsFeedbackSound,
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
        manager.conversationOpened(agentId: "agent-1", connectionId: Self.connectionId)
        manager.workspaceOpened(workspaceId: "workspace-1", connectionId: Self.connectionId)

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
        manager.conversationOpened(agentId: "agent-1", connectionId: Self.connectionId)

        manager.presentIdleAlert(
            agentId: "agent-1", workspaceId: "workspace-1", agentName: "Build Agent")

        #expect(center.requests.isEmpty)
        #expect(feedbackCount == 1)
        #expect(manager.currentToast == nil)
    }

    @Test @MainActor func openConversationOnAnotherBackendDoesNotSuppressToast() {
        // Suppression is connection-scoped: the same agent id open on
        // ANOTHER backend's window must not swallow this backend's toast.
        let (manager, _) = makeNotificationManager(state: .active)
        manager.conversationOpened(agentId: "agent-1", connectionId: UUID())

        manager.presentIdleAlert(
            agentId: "agent-1", workspaceId: "workspace-1", agentName: "Build Agent")

        #expect(manager.currentToast?.agentId == "agent-1")
        #expect(manager.currentToast?.sourceBackendID == BackendID(Self.connectionId))
    }

    @Test @MainActor func closedConversationStopsSuppressingItsBackendToast() {
        let (manager, _) = makeNotificationManager(state: .active)
        manager.conversationOpened(agentId: "agent-1", connectionId: Self.connectionId)
        manager.conversationClosed(agentId: "agent-1", connectionId: Self.connectionId)

        manager.presentIdleAlert(
            agentId: "agent-1", workspaceId: "workspace-1", agentName: "Build Agent")

        #expect(manager.currentToast?.agentId == "agent-1")
    }

    @Test @MainActor func conversationOpenInSiblingWindowKeepsSuppressingAfterOneClose() {
        // Visibility is counted per (id, connection): two windows on the
        // SAME backend can show the same conversation, and closing one
        // must not stop suppressing while the sibling still shows it.
        let (manager, _) = makeNotificationManager(state: .active)
        manager.conversationOpened(agentId: "agent-1", connectionId: Self.connectionId)
        manager.conversationOpened(agentId: "agent-1", connectionId: Self.connectionId)
        manager.conversationClosed(agentId: "agent-1", connectionId: Self.connectionId)

        manager.presentIdleAlert(
            agentId: "agent-1", workspaceId: "workspace-1", agentName: "Build Agent")
        #expect(manager.currentToast == nil,
                "The conversation is still visible in the sibling window")

        manager.conversationClosed(agentId: "agent-1", connectionId: Self.connectionId)
        manager.presentIdleAlert(
            agentId: "agent-1", workspaceId: "workspace-1", agentName: "Build Agent")
        #expect(manager.currentToast?.agentId == "agent-1",
                "The last close stops the suppression")
    }

    @Test @MainActor func workspaceOpenInSiblingWindowKeepsSuppressingAfterOneClose() {
        // Same counted semantics for workspace-detail visibility.
        let (manager, _) = makeNotificationManager(state: .active)
        manager.workspaceOpened(workspaceId: "workspace-1", connectionId: Self.connectionId)
        manager.workspaceOpened(workspaceId: "workspace-1", connectionId: Self.connectionId)
        manager.workspaceClosed(workspaceId: "workspace-1", connectionId: Self.connectionId)

        manager.presentIdleAlert(
            agentId: "agent-1", workspaceId: "workspace-1", agentName: "Build Agent")
        #expect(manager.currentToast == nil,
                "The workspace is still visible in the sibling window")

        manager.workspaceClosed(workspaceId: "workspace-1", connectionId: Self.connectionId)
        manager.presentIdleAlert(
            agentId: "agent-1", workspaceId: "workspace-1", agentName: "Build Agent")
        #expect(manager.currentToast?.workspaceId == "workspace-1",
                "The last close stops the suppression")
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

    private func makeResponse(connectionId: UUID) -> LocalNotificationService.Response {
        LocalNotificationService.response(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: [
                "agentId": "agent-1",
                "workspaceId": "workspace-1",
                "agentName": "Build Agent",
                "connectionId": connectionId.uuidString,
            ])
    }

    @Test @MainActor func notificationTapRoutesAfterColdStartHandlerInstallation() {
        let (manager, _) = makeNotificationManager(state: .inactive)
        var routedValues: (String, String, String)?

        manager.handleNotificationResponse(makeResponse(connectionId: Self.connectionId))
        manager.registerAgentSelectionHandler(
            for: BackendID(Self.connectionId)
        ) { agentId, workspaceId, agentName, _ in
            routedValues = (agentId, workspaceId, agentName)
        }

        #expect(routedValues?.0 == "agent-1")
        #expect(routedValues?.1 == "workspace-1")
        #expect(routedValues?.2 == "Build Agent")
    }

    @Test @MainActor func singleWindowTapForAnotherBackendIsDropped() {
        // iPhone showing backend A: a tap for backend B is dropped — same
        // visible behavior as the old coordinator-side connection guard —
        // and must not fire later when A's window re-registers.
        let (manager, _) = makeNotificationManager(state: .inactive)
        let windowBackend = BackendID(Self.connectionId)
        var didRoute = false
        manager.registerAgentSelectionHandler(for: windowBackend) { _, _, _, _ in
            didRoute = true
        }

        manager.handleNotificationResponse(makeResponse(connectionId: UUID()))
        #expect(!didRoute)

        manager.registerAgentSelectionHandler(for: windowBackend) { _, _, _, _ in
            didRoute = true
        }
        #expect(!didRoute)
    }

    @Test @MainActor func tapForUnshownBackendOpensItsWindowThenDeliversOnRegistration() {
        // Multi-window: a tap for a backend with no window opens that
        // backend's window; the held tap is delivered — with the SOURCE
        // connection id — once the opened window registers its handler.
        let (manager, _) = makeNotificationManager(state: .inactive)
        manager.supportsMultipleWindows = true
        var openedWindows: [BackendID] = []
        manager.openBackendWindow = { openedWindows.append($0) }
        let sourceConnectionId = UUID()
        manager.registerAgentSelectionHandler(
            for: BackendID(Self.connectionId)
        ) { _, _, _, _ in
            Issue.record("The tap must not land on another backend's window")
        }

        manager.handleNotificationResponse(makeResponse(connectionId: sourceConnectionId))
        #expect(openedWindows == [BackendID(sourceConnectionId)])

        var routedConnectionId: UUID?
        manager.registerAgentSelectionHandler(
            for: BackendID(sourceConnectionId)
        ) { _, _, _, connectionId in
            routedConnectionId = connectionId
        }
        #expect(routedConnectionId == sourceConnectionId)
    }

    @Test @MainActor func toastTapRoutesToSourceBackendWindow() {
        // Toast taps go through the same routing as system-notification
        // taps: whichever window renders the toast, the tap is delivered to
        // the source backend's registered window.
        let (manager, _) = makeNotificationManager(state: .active)
        let source = BackendID(Self.connectionId)
        var routedValues: (String, UUID)?
        manager.registerAgentSelectionHandler(for: source) { agentId, _, _, connectionId in
            routedValues = (agentId, connectionId)
        }

        manager.routeAgentSelection(
            agentId: "agent-1", workspaceId: "workspace-1",
            agentName: "Build Agent", connectionId: source.connectionID)

        #expect(routedValues?.0 == "agent-1")
        #expect(routedValues?.1 == source.connectionID)
    }

    @Test @MainActor func staleWindowTeardownDoesNotRemoveReplacementHandler() {
        // A rebound window's disappear runs after its replacement has
        // registered: the token guard keeps the replacement's handler.
        let (manager, _) = makeNotificationManager(state: .inactive)
        let backend = BackendID(Self.connectionId)
        let staleToken = manager.registerAgentSelectionHandler(for: backend) { _, _, _, _ in
            Issue.record("The stale handler must have been replaced")
        }
        var didRoute = false
        _ = manager.registerAgentSelectionHandler(for: backend) { _, _, _, _ in
            didRoute = true
        }

        manager.removeAgentSelectionHandler(for: backend, token: staleToken)
        manager.handleNotificationResponse(makeResponse(connectionId: Self.connectionId))

        #expect(didRoute)
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
        manager.registerAgentSelectionHandler(
            for: BackendID(Self.connectionId)
        ) { _, _, _, _ in didRoute = true }

        manager.handleNotificationResponse(response)

        #expect(!didRoute)
    }

    @Test @MainActor func openingConversationClearsDeliveredAgentNotification() {
        let (manager, center) = makeNotificationManager(state: .active)

        manager.conversationOpened(agentId: "agent-1", connectionId: Self.connectionId)

        #expect(center.removedNotificationIdentifiers == [[
            "agent-idle-\(Self.connectionId.uuidString)-agent-1"
        ]])
    }

    @Test @MainActor func openingConversationClearsNotificationScopedToItsConnection() {
        // The cleared identifier carries the conversation's OWN connection
        // id, not a global active-connection pointer.
        let (manager, center) = makeNotificationManager(state: .active)
        let pinnedConnectionId = UUID()

        manager.conversationOpened(agentId: "agent-1", connectionId: pinnedConnectionId)

        #expect(center.removedNotificationIdentifiers == [[
            "agent-idle-\(pinnedConnectionId.uuidString)-agent-1"
        ]])
    }

    // MARK: - Multi-window tap routing (spec decision 5)

    private static let pinnedBackend = BackendID(UUID(
        uuidString: "22222222-2222-2222-2222-222222222222")!)

    @Test func routeDeliversToRegisteredSourceWindow() {
        #expect(NotificationManager.selectionRoute(
            source: Self.pinnedBackend,
            registeredBackends: [Self.pinnedBackend, BackendID(UUID())],
            supportsMultipleWindows: false) == .deliverToWindow)
        #expect(NotificationManager.selectionRoute(
            source: Self.pinnedBackend,
            registeredBackends: [Self.pinnedBackend],
            supportsMultipleWindows: true) == .deliverToWindow)
    }

    @Test func routeOpensSourceWindowWhereMultipleWindowsSupported() {
        #expect(NotificationManager.selectionRoute(
            source: Self.pinnedBackend,
            registeredBackends: [BackendID(UUID())],
            supportsMultipleWindows: true) == .openSourceWindow)
        #expect(NotificationManager.selectionRoute(
            source: Self.pinnedBackend,
            registeredBackends: [],
            supportsMultipleWindows: true) == .openSourceWindow)
    }

    @Test func routeHoldsColdStartTapForFirstWindow() {
        #expect(NotificationManager.selectionRoute(
            source: Self.pinnedBackend,
            registeredBackends: [],
            supportsMultipleWindows: false) == .holdForFirstWindow)
    }

    @Test func routeDropsCrossBackendTapOnSingleWindowPlatform() {
        #expect(NotificationManager.selectionRoute(
            source: Self.pinnedBackend,
            registeredBackends: [BackendID(UUID())],
            supportsMultipleWindows: false) == .drop)
    }

    // MARK: - Presentation routing (per-backend windows)

    @Test func singleWindowRendersEveryToast() {
        // iPhone: the sole window renders the toast regardless of its bound
        // backend — unchanged behavior.
        #expect(NotificationManager.windowPresentsAlert(
            source: Self.pinnedBackend,
            windowBackendID: Self.pinnedBackend,
            supportsMultipleWindows: false))
        #expect(NotificationManager.windowPresentsAlert(
            source: Self.pinnedBackend,
            windowBackendID: BackendID(UUID()),
            supportsMultipleWindows: false))
        #expect(NotificationManager.windowPresentsAlert(
            source: Self.pinnedBackend,
            windowBackendID: nil,
            supportsMultipleWindows: false))
    }

    @Test func multiWindowRendersToastOnlyInSourceBackendWindow() {
        #expect(NotificationManager.windowPresentsAlert(
            source: Self.pinnedBackend,
            windowBackendID: Self.pinnedBackend,
            supportsMultipleWindows: true))
        #expect(!NotificationManager.windowPresentsAlert(
            source: Self.pinnedBackend,
            windowBackendID: BackendID(UUID()),
            supportsMultipleWindows: true))
        #expect(!NotificationManager.windowPresentsAlert(
            source: Self.pinnedBackend,
            windowBackendID: nil,
            supportsMultipleWindows: true),
            "A pairing window (no backend) renders no toasts on multi-window platforms")
    }

    @Test func singleWindowAlwaysPresentsAlerts() {
        #expect(NotificationManager.alertPresents(
            source: Self.pinnedBackend,
            registeredBackends: [],
            supportsMultipleWindows: false))
        #expect(NotificationManager.alertPresents(
            source: Self.pinnedBackend,
            registeredBackends: [BackendID(UUID())],
            supportsMultipleWindows: false))
    }

    @Test func multiWindowPresentsAlertOnlyWhenSourceWindowRegistered() {
        #expect(NotificationManager.alertPresents(
            source: Self.pinnedBackend,
            registeredBackends: [Self.pinnedBackend, BackendID(UUID())],
            supportsMultipleWindows: true))
        #expect(!NotificationManager.alertPresents(
            source: Self.pinnedBackend,
            registeredBackends: [BackendID(UUID())],
            supportsMultipleWindows: true))
        #expect(!NotificationManager.alertPresents(
            source: Self.pinnedBackend,
            registeredBackends: [],
            supportsMultipleWindows: true))
    }

    @Test @MainActor func multiWindowAlertPresentsViaRegisteredSourceWindow() {
        var feedbackCount = 0
        let (manager, _) = makeNotificationManager(state: .active) {
            feedbackCount += 1
        }
        manager.supportsMultipleWindows = true
        manager.registerAgentSelectionHandler(
            for: BackendID(Self.connectionId)) { _, _, _, _ in }

        manager.presentIdleAlert(
            agentId: "agent-1", workspaceId: "workspace-1", agentName: "Build Agent")

        #expect(feedbackCount == 1)
        #expect(manager.currentToast?.agentId == "agent-1")
    }

    @Test @MainActor func multiWindowAlertWithoutSourceWindowPresentsNothing() {
        // visionOS/iPad: an alert whose source backend has no registered
        // window plays no feedback and stores no toast — it would render
        // nowhere and clobber another backend's visible toast.
        var feedbackCount = 0
        let (manager, center) = makeNotificationManager(state: .active) {
            feedbackCount += 1
        }
        manager.supportsMultipleWindows = true
        manager.registerAgentSelectionHandler(for: BackendID(UUID())) { _, _, _, _ in }

        manager.presentIdleAlert(
            agentId: "agent-1", workspaceId: "workspace-1", agentName: "Build Agent")

        #expect(feedbackCount == 0)
        #expect(manager.currentToast == nil)
        #expect(center.requests.isEmpty)
    }

    @Test @MainActor func multiWindowSuppressedAlertStillPlaysFeedbackInSourceWindow() {
        // The connection-scoped suppression downgrade (open conversation →
        // feedback only) keeps working when the source window is registered.
        var feedbackCount = 0
        let (manager, _) = makeNotificationManager(state: .active) {
            feedbackCount += 1
        }
        manager.supportsMultipleWindows = true
        manager.registerAgentSelectionHandler(
            for: BackendID(Self.connectionId)) { _, _, _, _ in }
        manager.conversationOpened(agentId: "agent-1", connectionId: Self.connectionId)

        manager.presentIdleAlert(
            agentId: "agent-1", workspaceId: "workspace-1", agentName: "Build Agent")

        #expect(feedbackCount == 1)
        #expect(manager.currentToast == nil)
    }

    // MARK: - Window-emitted feedback sound (visionOS spatial audio)

    @Test @MainActor func windowEmittingAlertPublishesEventInsteadOfGlobalFeedback() {
        // visionOS: the manager publishes a per-backend feedback request
        // for the source window to emit spatially instead of playing the
        // global (non-spatial) sound.
        var feedbackCount = 0
        let (manager, _) = makeNotificationManager(
            state: .active, windowEmitsFeedbackSound: true) { feedbackCount += 1 }
        manager.supportsMultipleWindows = true
        manager.registerAgentSelectionHandler(
            for: BackendID(Self.connectionId)) { _, _, _, _ in }

        manager.presentIdleAlert(
            agentId: "agent-1", workspaceId: "workspace-1", agentName: "Build Agent")

        #expect(feedbackCount == 0)
        #expect(manager.windowFeedbackEvent?.sourceBackendID == BackendID(Self.connectionId))
        #expect(manager.currentToast?.agentId == "agent-1")
    }

    @Test @MainActor func windowEmittingSuppressedAlertStillPublishesEvent() {
        // The suppression downgrade (open conversation → feedback only)
        // still emits the sound from the source window, with no toast.
        var feedbackCount = 0
        let (manager, _) = makeNotificationManager(
            state: .active, windowEmitsFeedbackSound: true) { feedbackCount += 1 }
        manager.supportsMultipleWindows = true
        manager.registerAgentSelectionHandler(
            for: BackendID(Self.connectionId)) { _, _, _, _ in }
        manager.conversationOpened(agentId: "agent-1", connectionId: Self.connectionId)

        manager.presentIdleAlert(
            agentId: "agent-1", workspaceId: "workspace-1", agentName: "Build Agent")

        #expect(feedbackCount == 0)
        #expect(manager.windowFeedbackEvent?.sourceBackendID == BackendID(Self.connectionId))
        #expect(manager.currentToast == nil)
    }

    @Test @MainActor func repeatWindowEmittedAlertsPublishDistinctEventIds() {
        // Each request carries a fresh id so a window's onChange re-fires
        // for back-to-back alerts from the same backend.
        let (manager, _) = makeNotificationManager(
            state: .active, windowEmitsFeedbackSound: true)
        manager.supportsMultipleWindows = true
        manager.registerAgentSelectionHandler(
            for: BackendID(Self.connectionId)) { _, _, _, _ in }

        manager.presentIdleAlert(
            agentId: "agent-1", workspaceId: "workspace-1", agentName: "Build Agent")
        let first = manager.windowFeedbackEvent
        manager.presentIdleAlert(
            agentId: "agent-2", workspaceId: "workspace-2", agentName: "Test Agent")

        #expect(first != nil)
        #expect(manager.windowFeedbackEvent != nil)
        #expect(manager.windowFeedbackEvent != first)
    }

    @Test @MainActor func globalFeedbackPathNeverPublishesWindowEvent() {
        // iPhone/iPad: the global haptic + sound closure keeps playing and
        // no window event is published.
        var feedbackCount = 0
        let (manager, _) = makeNotificationManager(state: .active) {
            feedbackCount += 1
        }

        manager.presentIdleAlert(
            agentId: "agent-1", workspaceId: "workspace-1", agentName: "Build Agent")

        #expect(feedbackCount == 1)
        #expect(manager.windowFeedbackEvent == nil)
    }
}

// MARK: - Notification chime synthesis

/// The chime WAV backs the visionOS window-emitted sound
/// (`WindowFeedbackSoundEmitter`); the synthesis is platform-independent so
/// the iOS suite validates it.
@Suite("NotificationChime synthesis")
struct NotificationChimeTests {
    @Test func wavDataHasValidRiffHeader() {
        let data = NotificationChime.wavData()
        #expect(data.count > 44)
        #expect(String(data: data.prefix(4), encoding: .ascii) == "RIFF")
        #expect(String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE")
        let bytes = [UInt8](data.subdata(in: 4..<8))
        let chunkSize = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        #expect(Int(chunkSize) == data.count - 8)
    }

    @Test func chimeIsAudible() {
        let samples = NotificationChime.chimeSamples()
        #expect(samples.contains { abs(Int($0)) > 8_000 })
    }

    @Test func fileURLIsCreatedOnceAndStable() throws {
        let first = try #require(NotificationChime.fileURL())
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(NotificationChime.fileURL() == first)
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
        defaultConnection: FakeConnectionManager,
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
            registerEvents: false)
        return (manager, center)
    }

    private func makeSession(
        backendID: BackendID?, connection: SessionFakeConnectionManager,
        attentionCueCenter: WorkspaceAttentionCueCenter =
            WorkspaceAttentionCueCenter(playSound: {})
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
            githubRepoStore: GitHubRepoStore(connectionManager: connection),
            creationOptionsStore: CreationOptionsStore(connectionManager: connection),
            prMonitorsStore: WorkspacePrMonitorsStore(connectionManager: connection),
            attachmentUploadService: AttachmentUploadService(connection: connection),
            workspaceFileImageLoader: fileLoader,
            attachmentImageLoader: AttachmentImageLoader(
                connection: connection, fileLoader: fileLoader),
            attentionCueCenter: attentionCueCenter)
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

    // MARK: - Alert-chime / attention-cue dedup (visionOS double chime)

    private func makeCueWorkspace(id: String, attention: String? = nil) -> Workspace {
        Workspace(id: id, title: "Test", branch: nil, baseRef: nil, status: nil,
                  activity: nil, displayStatus: nil, attention: attention,
                  lastActivity: nil, updatedAt: nil, repositoryOwner: nil,
                  repositoryName: nil, prStatus: nil, prNumber: nil,
                  diffSummaryTotalFiles: nil, taskStatsTotal: nil,
                  taskStatsCompleted: nil, taskStatsInProgress: nil,
                  agentSummaryCount: nil, agentSummaryAgents: nil)
    }

    @Test func idleAlertChimeThenAttentionFlipYieldsOneAudibleTrigger() async throws {
        // agent:idle chimes via the observed session, then the same
        // completion flips the workspace to unread: the cue stays silent.
        let (manager, _) = makeManager(
            defaultConnection: FakeConnectionManager(), windowEmitsFeedbackSound: true)
        let backendID = BackendID(UUID())
        let connection = SessionFakeConnectionManager()
        connection.responseMap["agent.list"] = ["agents": [[String: Any]]()]
        let cueCenter = WorkspaceAttentionCueCenter(
            playSound: {}, windowEmitsCueSound: true)
        let session = makeSession(
            backendID: backendID, connection: connection,
            attentionCueCenter: cueCenter)
        manager.attachSessionObserver(for: session)
        cueCenter.observe(workspaces: [makeCueWorkspace(id: "ws-p")])

        connection.deliverEvent(
            method: "event",
            params: idleEventParams(agentId: "agent-p", workspaceId: "ws-p"))
        try await waitFor { manager.windowFeedbackEvent != nil }

        cueCenter.observe(workspaces: [makeCueWorkspace(id: "ws-p", attention: "unread")])
        #expect(cueCenter.windowCueEvent == nil,
                "The alert chime already sounded for ws-p — no second chime")
    }

    @Test func attentionCueThenIdleAlertYieldsOneAudibleTrigger() async throws {
        // Reverse arrival order: the workspace snapshot flips first, then
        // the agent:idle alert arrives — the chime is suppressed.
        let (manager, _) = makeManager(
            defaultConnection: FakeConnectionManager(), windowEmitsFeedbackSound: true)
        let backendID = BackendID(UUID())
        let connection = SessionFakeConnectionManager()
        connection.responseMap["agent.list"] = ["agents": [[String: Any]]()]
        let cueCenter = WorkspaceAttentionCueCenter(
            playSound: {}, windowEmitsCueSound: true)
        let session = makeSession(
            backendID: backendID, connection: connection,
            attentionCueCenter: cueCenter)
        manager.attachSessionObserver(for: session)
        cueCenter.observe(workspaces: [makeCueWorkspace(id: "ws-p")])
        cueCenter.observe(workspaces: [makeCueWorkspace(id: "ws-p", attention: "unread")])
        #expect(cueCenter.windowCueEvent != nil)

        connection.deliverEvent(
            method: "event",
            params: idleEventParams(agentId: "agent-p", workspaceId: "ws-p"))
        try await waitFor { manager.currentToast != nil }

        #expect(manager.windowFeedbackEvent == nil,
                "The attention cue already sounded for ws-p — no alert chime")
        #expect(manager.currentToast != nil,
                "Dedup silences the sound only; the toast still shows")
    }
}
