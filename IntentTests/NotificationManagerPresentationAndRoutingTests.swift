import Foundation
@testable import Intent
import Testing
import UIKit
import UserNotifications

extension NotificationManagerTests {
    // MARK: - App-state presentation

    @Test @MainActor func inactiveAppPostsSystemNotificationWithoutFeedbackOrToast() {
        var feedbackCount = 0
        let (manager, center) = makeNotificationManager(state: .inactive) {
            feedbackCount += 1
        }
        manager.conversationOpened(agentId: "agent-1", connectionId: Self.connectionId)
        manager.workspaceOpened(workspaceId: "workspace-1", connectionId: Self.connectionId)

        manager.presentIdleAlert(
            agentId: "agent-1",
            workspaceId: "workspace-1",
            agentName: "Build Agent"
        )

        #expect(center.requests.count == 1)
        #expect(feedbackCount == 0)
        #expect(manager.currentToast == nil)
    }

    @Test @MainActor func backgroundAppPostsSystemNotification() {
        let (manager, center) = makeNotificationManager(state: .background)

        manager.presentIdleAlert(
            agentId: "agent-1",
            workspaceId: "workspace-1",
            agentName: "Build Agent"
        )

        #expect(center.requests.count == 1)
    }

    @Test @MainActor func activeAppPostsSystemSoundAndKeepsFeedbackAndToast() {
        var feedbackCount = 0
        let (manager, center) = makeNotificationManager(state: .active) {
            feedbackCount += 1
        }

        manager.presentIdleAlert(
            agentId: "agent-1",
            workspaceId: "workspace-1",
            agentName: "Build Agent"
        )

        #expect(center.requests.count == 1)
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
            agentId: "agent-1",
            workspaceId: "workspace-1",
            agentName: "Build Agent"
        )

        #expect(center.requests.count == 1)
        #expect(feedbackCount == 1)
        #expect(manager.currentToast == nil)
    }

    @Test @MainActor func openConversationOnAnotherBackendDoesNotSuppressToast() {
        // Suppression is connection-scoped: the same agent id open on
        // ANOTHER backend's window must not swallow this backend's toast.
        let (manager, _) = makeNotificationManager(state: .active)
        manager.conversationOpened(agentId: "agent-1", connectionId: UUID())

        manager.presentIdleAlert(
            agentId: "agent-1",
            workspaceId: "workspace-1",
            agentName: "Build Agent"
        )

        #expect(manager.currentToast?.agentId == "agent-1")
        #expect(manager.currentToast?.sourceBackendID == BackendID(Self.connectionId))
    }

    @Test @MainActor func closedConversationStopsSuppressingItsBackendToast() {
        let (manager, _) = makeNotificationManager(state: .active)
        manager.conversationOpened(agentId: "agent-1", connectionId: Self.connectionId)
        manager.conversationClosed(agentId: "agent-1", connectionId: Self.connectionId)

        manager.presentIdleAlert(
            agentId: "agent-1",
            workspaceId: "workspace-1",
            agentName: "Build Agent"
        )

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
            agentId: "agent-1",
            workspaceId: "workspace-1",
            agentName: "Build Agent"
        )
        #expect(
            manager.currentToast == nil,
            "The conversation is still visible in the sibling window"
        )

        manager.conversationClosed(agentId: "agent-1", connectionId: Self.connectionId)
        manager.presentIdleAlert(
            agentId: "agent-1",
            workspaceId: "workspace-1",
            agentName: "Build Agent"
        )
        #expect(
            manager.currentToast?.agentId == "agent-1",
            "The last close stops the suppression"
        )
    }

    @Test @MainActor func workspaceOpenInSiblingWindowKeepsSuppressingAfterOneClose() {
        // Same counted semantics for workspace-detail visibility.
        let (manager, _) = makeNotificationManager(state: .active)
        manager.workspaceOpened(workspaceId: "workspace-1", connectionId: Self.connectionId)
        manager.workspaceOpened(workspaceId: "workspace-1", connectionId: Self.connectionId)
        manager.workspaceClosed(workspaceId: "workspace-1", connectionId: Self.connectionId)

        manager.presentIdleAlert(
            agentId: "agent-1",
            workspaceId: "workspace-1",
            agentName: "Build Agent"
        )
        #expect(
            manager.currentToast == nil,
            "The workspace is still visible in the sibling window"
        )

        manager.workspaceClosed(workspaceId: "workspace-1", connectionId: Self.connectionId)
        manager.presentIdleAlert(
            agentId: "agent-1",
            workspaceId: "workspace-1",
            agentName: "Build Agent"
        )
        #expect(
            manager.currentToast?.workspaceId == "workspace-1",
            "The last close stops the suppression"
        )
    }

    @Test func foregroundDeliveryPresentsFeedbackAndToastWithSystemSoundOnly() async {
        let center = NotificationManagerFakeCenter()
        let service = LocalNotificationService(center: center) { 1 }
        var feedbackCount = 0
        let manager = NotificationManager(
            localNotificationService: service,
            applicationState: { .active },
            activeConnectionId: { Self.connectionId },
            presentFeedback: { feedbackCount += 1 },
            registerEvents: false
        )
        let response = LocalNotificationService.response(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: [
                "agentId": "agent-1",
                "workspaceId": "workspace-1",
                "agentName": "Build Agent",
                "connectionId": Self.connectionId.uuidString
            ]
        )

        let options = await withCheckedContinuation { continuation in
            service.deliverForegroundNotification(response) { options in
                continuation.resume(returning: options)
            }
        }

        #expect(options == [.sound])
        #expect(feedbackCount == 1)
        #expect(manager.currentToast?.agentId == "agent-1")
        #expect(center.requests.isEmpty)
    }

    // MARK: - Tap routing and delivered cleanup

    private func makeResponse(connectionId: UUID) -> LocalNotificationService.Response {
        LocalNotificationService.response(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: [
                "agentId": "agent-1",
                "workspaceId": "workspace-1",
                "agentName": "Build Agent",
                "connectionId": connectionId.uuidString
            ]
        )
    }

    @Test @MainActor func notificationTapRoutesAfterColdStartHandlerInstallation() {
        let (manager, _) = makeNotificationManager(state: .inactive)
        var routedAgentId: String?
        var routedWorkspaceId: String?
        var routedAgentName: String?

        manager.handleNotificationResponse(makeResponse(connectionId: Self.connectionId))
        manager.registerAgentSelectionHandler(
            for: BackendID(Self.connectionId)
        ) { agentId, workspaceId, agentName, _ in
            routedAgentId = agentId
            routedWorkspaceId = workspaceId
            routedAgentName = agentName
        }

        #expect(routedAgentId == "agent-1")
        #expect(routedWorkspaceId == "workspace-1")
        #expect(routedAgentName == "Build Agent")
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
            agentId: "agent-1",
            workspaceId: "workspace-1",
            agentName: "Build Agent",
            connectionId: source.connectionID
        )

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
                "agentName": "Build Agent"
            ]
        )
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

        #expect(center.removedNotificationIdentifiers == [
            [
                "agent-idle-\(Self.connectionId.uuidString)-agent-1"
            ]
        ])
    }

    @Test @MainActor func openingConversationClearsNotificationScopedToItsConnection() {
        // The cleared identifier carries the conversation's OWN connection
        // id, not a global active-connection pointer.
        let (manager, center) = makeNotificationManager(state: .active)
        let pinnedConnectionId = UUID()

        manager.conversationOpened(agentId: "agent-1", connectionId: pinnedConnectionId)

        #expect(center.removedNotificationIdentifiers == [
            [
                "agent-idle-\(pinnedConnectionId.uuidString)-agent-1"
            ]
        ])
    }
}
