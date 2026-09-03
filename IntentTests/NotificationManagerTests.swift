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

    private func makeNotificationManager(
        state: UIApplication.State,
        feedback: @escaping () -> Void = {}
    ) -> (NotificationManager, NotificationManagerFakeCenter) {
        let center = NotificationManagerFakeCenter()
        let service = LocalNotificationService(center: center)
        let manager = NotificationManager(
            localNotificationService: service,
            applicationState: { state },
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

    // MARK: - Tap routing and delivered cleanup

    @Test @MainActor func notificationTapRoutesAfterColdStartHandlerInstallation() {
        let (manager, _) = makeNotificationManager(state: .inactive)
        let response = LocalNotificationService.response(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: [
                "agentId": "agent-1",
                "workspaceId": "workspace-1",
                "agentName": "Build Agent",
            ])
        var routedValues: (String, String, String)?

        manager.handleNotificationResponse(response)
        manager.setAgentSelectionHandler { routedValues = ($0, $1, $2) }

        #expect(routedValues?.0 == "agent-1")
        #expect(routedValues?.1 == "workspace-1")
        #expect(routedValues?.2 == "Build Agent")
    }

    @Test @MainActor func openingConversationClearsDeliveredAgentNotification() {
        let (manager, center) = makeNotificationManager(state: .active)

        manager.currentAgentId = "agent-1"

        #expect(center.removedNotificationIdentifiers == [["agent-idle-agent-1"]])
    }
}
