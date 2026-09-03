import Foundation
import Testing
import UserNotifications
@testable import Intent

@MainActor
private final class FakeLocalNotificationCenter: LocalNotificationCenter {
    weak var delegate: (any UNUserNotificationCenterDelegate)?
    private(set) var authorizationOptions: [UNAuthorizationOptions] = []
    private(set) var requests: [UNNotificationRequest] = []
    private(set) var removedNotificationIdentifiers: [[String]] = []
    var authorizationStatus: UNAuthorizationStatus = .notDetermined
    var authorizationGranted = true
    var completesAuthorizationRequest = true

    func getAuthorizationStatus(
        completionHandler: @escaping @MainActor @Sendable (UNAuthorizationStatus) -> Void
    ) {
        completionHandler(authorizationStatus)
    }

    func requestAuthorization(
        options: UNAuthorizationOptions,
        completionHandler: @escaping @Sendable (Bool, (any Error)?) -> Void
    ) {
        authorizationOptions.append(options)
        if completesAuthorizationRequest {
            completionHandler(authorizationGranted, nil)
        }
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

@Suite("Local notification service")
@MainActor
struct LocalNotificationServiceTests {
    @Test func notDeterminedAuthorizationIsRequested() {
        let center = FakeLocalNotificationCenter()
        center.authorizationStatus = .notDetermined
        let service = LocalNotificationService(center: center)

        service.requestAuthorizationIfNeeded()

        #expect(center.authorizationOptions == [[.alert, .sound]])
    }

    @Test(arguments: [UNAuthorizationStatus.authorized, .denied])
    func determinedAuthorizationIsNotRequested(status: UNAuthorizationStatus) {
        let center = FakeLocalNotificationCenter()
        center.authorizationStatus = status
        let service = LocalNotificationService(center: center)

        service.requestAuthorizationIfNeeded()

        #expect(center.authorizationOptions.isEmpty)
    }

    @Test func notificationManagerRequestsAuthorizationAtStartupWithoutWaiting() {
        let center = FakeLocalNotificationCenter()
        center.completesAuthorizationRequest = false
        let service = LocalNotificationService(center: center)

        _ = NotificationManager(localNotificationService: service, registerEvents: false)

        #expect(center.authorizationOptions == [[.alert, .sound]])
    }

    @Test func postsExpectedAgentCompletionRequest() {
        let center = FakeLocalNotificationCenter()
        let service = LocalNotificationService(center: center)

        service.postAgentIdleNotification(
            agentId: "agent-1", workspaceId: "workspace-1",
            agentName: "Build Agent", workspaceName: "iOS App")

        guard let request = center.requests.first else {
            Issue.record("Expected a notification request")
            return
        }
        #expect(request.identifier == "agent-idle-agent-1")
        #expect(request.trigger == nil)
        #expect(request.content.title == "Build Agent")
        #expect(request.content.body == "Finished in iOS App")
        #expect(request.content.sound != nil)
        #expect(request.content.userInfo["agentId"] as? String == "agent-1")
        #expect(request.content.userInfo["workspaceId"] as? String == "workspace-1")
        #expect(request.content.userInfo["agentName"] as? String == "Build Agent")
    }

    @Test func delegateIsInstalledAndSuppressesForegroundPresentation() {
        let center = FakeLocalNotificationCenter()
        let service = LocalNotificationService(center: center)

        #expect(center.delegate === service)
        #expect(LocalNotificationService.presentationOptionsForForegroundNotification().isEmpty)
    }

    @Test func removesDeliveredNotificationForAgent() {
        let center = FakeLocalNotificationCenter()
        let service = LocalNotificationService(center: center)

        service.removeDeliveredNotifications(forAgentId: "agent-1")

        #expect(center.removedNotificationIdentifiers == [["agent-idle-agent-1"]])
    }

    @Test func decodesNotificationResponsePayload() {
        let response = LocalNotificationService.response(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: [
                "agentId": "agent-1",
                "workspaceId": "workspace-1",
                "agentName": "Build Agent",
            ])

        #expect(response.actionIdentifier == UNNotificationDefaultActionIdentifier)
        #expect(response.agentId == "agent-1")
        #expect(response.workspaceId == "workspace-1")
        #expect(response.agentName == "Build Agent")
    }
}