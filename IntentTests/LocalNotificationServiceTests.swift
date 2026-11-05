import Foundation
@testable import Intent
import Synchronization
import Testing
import UserNotifications

@MainActor
private final class FakeLocalNotificationCenter: LocalNotificationCenter {
    weak var delegate: (any UNUserNotificationCenterDelegate)?
    private(set) var authorizationOptions: [UNAuthorizationOptions] = []
    private(set) var requests: [UNNotificationRequest] = []
    private(set) var removedNotificationIdentifiers: [[String]] = []
    var authorizationStatus: UNAuthorizationStatus = .notDetermined
    var authorizationGranted = true
    var completesAuthorizationRequest = true
    var soundEnabled = false

    func soundIsEnabled() -> Bool { soundEnabled }

    func getAuthorizationStatus(
        completionHandler: @MainActor @Sendable (UNAuthorizationStatus) -> Void
    ) {
        completionHandler(authorizationStatus)
    }

    func requestAuthorization(
        options: UNAuthorizationOptions,
        completionHandler: @Sendable (Bool, (any Error)?) -> Void
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

    @Test(arguments: [false, true], [Float(0), 0.01, 1])
    func postsExpectedAgentCompletionRequest(foregroundPresentationHandled: Bool, volume: Float) throws {
        let center = FakeLocalNotificationCenter()
        let service = LocalNotificationService(center: center, playForegroundSound: {}, outputVolume: { volume })
        let connectionId = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))

        service.postAgentIdleNotification(
            agentId: "agent-1",
            workspaceId: "workspace-1",
            agentName: "Build Agent",
            workspaceName: "iOS App",
            connectionId: connectionId,
            foregroundPresentationHandled: foregroundPresentationHandled
        )

        guard let request = center.requests.first else {
            Issue.record("Expected a notification request")
            return
        }
        #expect(request.identifier == "agent-idle-\(connectionId.uuidString)-agent-1")
        #expect(request.trigger == nil)
        #expect(request.content.title == "Build Agent")
        #expect(request.content.body == "Finished in iOS App")
        #expect((request.content.sound != nil) == (volume > 0))
        #expect(request.content.interruptionLevel == .active)
        #expect(request.content.userInfo["agentId"] as? String == "agent-1")
        #expect(request.content.userInfo["workspaceId"] as? String == "workspace-1")
        #expect(request.content.userInfo["agentName"] as? String == "Build Agent")
        #expect(request.content.userInfo["connectionId"] as? String == connectionId.uuidString)
        let response = LocalNotificationService.response(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: request.content.userInfo
        )
        #expect(response.foregroundPresentationHandled == foregroundPresentationHandled)
    }

    @Test func foregroundDeliveryWithoutHandlerIsSilent() async {
        let center = FakeLocalNotificationCenter()
        let service = LocalNotificationService(center: center)

        #expect(center.delegate === service)
        let response = LocalNotificationService.response(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: [:]
        )
        let options = await withCheckedContinuation { continuation in
            service.deliverForegroundNotification(response) { options in
                continuation.resume(returning: options)
            }
        }
        #expect(options.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func foregroundCompletionDoesNotWaitForTheChime() async {
        let center = FakeLocalNotificationCenter()
        center.soundEnabled = true
        let chimeGate = AsyncStream<Void>.makeStream()
        var chimeFinished = false
        let service = LocalNotificationService(
            center: center,
            playForegroundSound: {
                for await _ in chimeGate.stream {}
                chimeFinished = true
            },
            outputVolume: { 1 }
        )
        service.onWillPresentNotification = { _ in [.banner, .sound] }
        let response = LocalNotificationService.response(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: [:]
        )

        let options = await withCheckedContinuation { continuation in
            service.deliverForegroundNotification(response) { options in
                continuation.resume(returning: options)
            }
        }

        #expect(options == [.banner])
        #expect(!chimeFinished)
        chimeGate.continuation.finish()
        await service.foregroundSoundTask?.value
        #expect(chimeFinished)
    }

    @Test func removesDeliveredNotificationForAgent() throws {
        let center = FakeLocalNotificationCenter()
        let service = LocalNotificationService(center: center)
        let connectionId = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))

        service.removeDeliveredNotifications(forAgentId: "agent-1", connectionId: connectionId)

        #expect(center.removedNotificationIdentifiers == [
            [
                "agent-idle-\(connectionId.uuidString)-agent-1"
            ]
        ])
    }

    @Test func decodesNotificationResponsePayload() throws {
        let connectionId = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let response = LocalNotificationService.response(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: [
                "agentId": "agent-1",
                "workspaceId": "workspace-1",
                "agentName": "Build Agent",
                "connectionId": connectionId.uuidString
            ]
        )

        #expect(response.actionIdentifier == UNNotificationDefaultActionIdentifier)
        #expect(response.agentId == "agent-1")
        #expect(response.workspaceId == "workspace-1")
        #expect(response.agentName == "Build Agent")
        #expect(response.connectionId == connectionId)
        #expect(!response.foregroundPresentationHandled)
    }

    @Test func notificationResponseCompletesAfterRoutingCallback() async {
        let center = FakeLocalNotificationCenter()
        let service = LocalNotificationService(center: center)
        let events = Mutex<[String]>([])
        let response = LocalNotificationService.response(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: [:]
        )
        service.onNotificationResponse = { _ in
            events.withLock { $0.append("routed") }
        }

        await withCheckedContinuation { continuation in
            service.deliverNotificationResponse(response) {
                events.withLock { $0.append("completed") }
                continuation.resume()
            }
        }

        #expect(events.withLock { $0 } == ["routed", "completed"])
    }
}
