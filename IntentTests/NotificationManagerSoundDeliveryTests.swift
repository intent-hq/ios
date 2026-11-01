import Foundation
@testable import Intent
import Testing
import UIKit
import UserNotifications

extension NotificationManagerTests {
    @Test(arguments: [Float(0), 1], [Float(0), 0.01, 1])
    func deliveryUsesCurrentVolumeAndKeepsToastAndHaptics(initialVolume: Float, deliveryVolume: Float) async throws {
        var volume = initialVolume
        var feedbackCount = 0
        let center = NotificationManagerFakeCenter()
        let service = LocalNotificationService(center: center, outputVolume: { volume })
        let manager = NotificationManager(
            localNotificationService: service,
            applicationState: { .active },
            activeConnectionId: { Self.connectionId },
            presentFeedback: { feedbackCount += 1 },
            registerEvents: false
        )
        manager.presentIdleAlert(
            agentId: "agent-1",
            workspaceId: "workspace-1",
            agentName: "Build Agent"
        )
        let request = try #require(center.requests.first)
        #expect((request.content.sound != nil) == (initialVolume > 0))
        volume = deliveryVolume

        let options = await deliver(request, through: service)

        #expect(options == (deliveryVolume > 0 ? [.sound] : []))
        #expect(manager.currentToast?.agentId == "agent-1")
        #expect(feedbackCount == 1)
    }

    @Test(arguments: [false, true])
    func foregroundSoundDeliveryDoesNotRepeatPresentation(dismissToast: Bool) async throws {
        var feedbackCount = 0
        let (manager, center) = makeNotificationManager(state: .active) {
            feedbackCount += 1
        }
        manager.presentIdleAlert(
            agentId: "agent-1",
            workspaceId: "workspace-1",
            agentName: "Build Agent"
        )
        let request = try #require(center.requests.first)
        let toast = try #require(manager.currentToast)
        if dismissToast { manager.dismissToast() }

        let options = await deliver(request, through: manager.localNotificationService)

        #expect(options == [.sound])
        #expect(feedbackCount == 1)
        #expect(manager.currentToast == (dismissToast ? nil : toast))
        #expect(center.requests.count == 1)
    }

    @Test(arguments: [false, true])
    func backgroundRequestArrivingInForegroundUsesPlatformSoundPolicy(
        windowEmitsFeedbackSound: Bool
    ) async throws {
        var state: UIApplication.State = .background
        var feedbackCount = 0
        let center = NotificationManagerFakeCenter()
        let service = LocalNotificationService(center: center, outputVolume: { 1 })
        let manager = NotificationManager(
            localNotificationService: service,
            applicationState: { state },
            activeConnectionId: { Self.connectionId },
            presentFeedback: { feedbackCount += 1 },
            windowEmitsFeedbackSound: windowEmitsFeedbackSound,
            registerEvents: false
        )
        manager.presentIdleAlert(
            agentId: "agent-1",
            workspaceId: "workspace-1",
            agentName: "Build Agent"
        )
        let request = try #require(center.requests.first)
        #expect(manager.currentToast == nil)
        #expect(feedbackCount == 0)
        state = .active

        let options = await deliver(request, through: service)

        #expect(options == (windowEmitsFeedbackSound ? [] : [.sound]))
        #expect(feedbackCount == (windowEmitsFeedbackSound ? 0 : 1))
        #expect((manager.windowFeedbackEvent != nil) == windowEmitsFeedbackSound)
        #expect(manager.currentToast?.agentId == "agent-1")
        #expect(center.requests.count == 1)
    }

    @Test(arguments: [UIApplication.State.active, .background])
    func closingSourceWindowBeforeDeliverySuppressesSystemSound(state: UIApplication.State) async throws {
        var feedbackCount = 0
        let (manager, center) = makeNotificationManager(state: state) {
            feedbackCount += 1
        }
        manager.supportsMultipleWindows = true
        let backendID = BackendID(Self.connectionId)
        let token = manager.registerAgentSelectionHandler(for: backendID) { _, _, _, _ in }
        manager.presentIdleAlert(
            agentId: "agent-1",
            workspaceId: "workspace-1",
            agentName: "Build Agent"
        )
        let request = try #require(center.requests.first)
        let toast = manager.currentToast
        manager.removeAgentSelectionHandler(for: backendID, token: token)

        let options = await deliver(request, through: manager.localNotificationService)

        #expect(options.isEmpty)
        #expect(feedbackCount == (state == .active ? 1 : 0))
        #expect(manager.currentToast == toast)
        #expect(center.requests.count == 1)
    }

    @Test func deniedNotificationsDoNotPreventInAppPresentation() {
        var feedbackCount = 0
        let (manager, center) = makeNotificationManager(state: .active) {
            feedbackCount += 1
        }
        center.authorizationStatus = .denied
        center.addError = NSError(domain: "NotificationPermissionDenied", code: 1)

        manager.presentIdleAlert(
            agentId: "agent-1",
            workspaceId: "workspace-1",
            agentName: "Build Agent"
        )

        #expect(feedbackCount == 1)
        #expect(manager.currentToast?.agentId == "agent-1")
        #expect(center.requests.count == 1)
        #expect(manager.windowFeedbackEvent == nil)
    }

    @Test func malformedForegroundNotificationDoesNotSound() async {
        var feedbackCount = 0
        let (manager, center) = makeNotificationManager(state: .active) {
            feedbackCount += 1
        }
        let request = UNNotificationRequest(
            identifier: "unknown",
            content: UNMutableNotificationContent(),
            trigger: nil
        )

        let options = await deliver(request, through: manager.localNotificationService)

        #expect(options.isEmpty)
        #expect(feedbackCount == 0)
        #expect(manager.currentToast == nil)
        #expect(center.requests.isEmpty)
    }

    private func deliver(
        _ request: UNNotificationRequest,
        through service: LocalNotificationService
    ) async -> UNNotificationPresentationOptions {
        let response = LocalNotificationService.response(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: request.content.userInfo
        )
        return await withCheckedContinuation { continuation in
            service.deliverForegroundNotification(response) { options in
                continuation.resume(returning: options)
            }
        }
    }
}
