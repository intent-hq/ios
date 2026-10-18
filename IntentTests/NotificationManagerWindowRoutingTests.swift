import Foundation
@testable import Intent
import Testing
import UIKit
import UserNotifications

extension NotificationManagerTests {
    // MARK: - Multi-window tap routing (spec decision 5)

    @Test func routeDeliversToRegisteredSourceWindow() {
        #expect(NotificationManager.selectionRoute(
            source: Self.pinnedBackend,
            registeredBackends: [Self.pinnedBackend, BackendID(UUID())],
            supportsMultipleWindows: false
        ) == .deliverToWindow)
        #expect(NotificationManager.selectionRoute(
            source: Self.pinnedBackend,
            registeredBackends: [Self.pinnedBackend],
            supportsMultipleWindows: true
        ) == .deliverToWindow)
    }

    @Test func routeOpensSourceWindowWhereMultipleWindowsSupported() {
        #expect(NotificationManager.selectionRoute(
            source: Self.pinnedBackend,
            registeredBackends: [BackendID(UUID())],
            supportsMultipleWindows: true
        ) == .openSourceWindow)
        #expect(NotificationManager.selectionRoute(
            source: Self.pinnedBackend,
            registeredBackends: [],
            supportsMultipleWindows: true
        ) == .openSourceWindow)
    }

    @Test func routeHoldsColdStartTapForFirstWindow() {
        #expect(NotificationManager.selectionRoute(
            source: Self.pinnedBackend,
            registeredBackends: [],
            supportsMultipleWindows: false
        ) == .holdForFirstWindow)
    }

    @Test func routeDropsCrossBackendTapOnSingleWindowPlatform() {
        #expect(NotificationManager.selectionRoute(
            source: Self.pinnedBackend,
            registeredBackends: [BackendID(UUID())],
            supportsMultipleWindows: false
        ) == .drop)
    }

    // MARK: - Presentation routing (per-backend windows)

    @Test func singleWindowRendersEveryToast() {
        // iPhone: the sole window renders the toast regardless of its bound
        // backend — unchanged behavior.
        #expect(NotificationManager.windowPresentsAlert(
            source: Self.pinnedBackend,
            windowBackendID: Self.pinnedBackend,
            supportsMultipleWindows: false
        ))
        #expect(NotificationManager.windowPresentsAlert(
            source: Self.pinnedBackend,
            windowBackendID: BackendID(UUID()),
            supportsMultipleWindows: false
        ))
        #expect(NotificationManager.windowPresentsAlert(
            source: Self.pinnedBackend,
            windowBackendID: nil,
            supportsMultipleWindows: false
        ))
    }

    @Test func multiWindowRendersToastOnlyInSourceBackendWindow() {
        #expect(NotificationManager.windowPresentsAlert(
            source: Self.pinnedBackend,
            windowBackendID: Self.pinnedBackend,
            supportsMultipleWindows: true
        ))
        #expect(!NotificationManager.windowPresentsAlert(
            source: Self.pinnedBackend,
            windowBackendID: BackendID(UUID()),
            supportsMultipleWindows: true
        ))
        #expect(
            !NotificationManager.windowPresentsAlert(
                source: Self.pinnedBackend,
                windowBackendID: nil,
                supportsMultipleWindows: true
            ),
            "A pairing window (no backend) renders no toasts on multi-window platforms"
        )
    }

    @Test func singleWindowAlwaysPresentsAlerts() {
        #expect(NotificationManager.alertPresents(
            source: Self.pinnedBackend,
            registeredBackends: [],
            supportsMultipleWindows: false
        ))
        #expect(NotificationManager.alertPresents(
            source: Self.pinnedBackend,
            registeredBackends: [BackendID(UUID())],
            supportsMultipleWindows: false
        ))
    }

    @Test func multiWindowPresentsAlertOnlyWhenSourceWindowRegistered() {
        #expect(NotificationManager.alertPresents(
            source: Self.pinnedBackend,
            registeredBackends: [Self.pinnedBackend, BackendID(UUID())],
            supportsMultipleWindows: true
        ))
        #expect(!NotificationManager.alertPresents(
            source: Self.pinnedBackend,
            registeredBackends: [BackendID(UUID())],
            supportsMultipleWindows: true
        ))
        #expect(!NotificationManager.alertPresents(
            source: Self.pinnedBackend,
            registeredBackends: [],
            supportsMultipleWindows: true
        ))
    }

    @Test @MainActor func multiWindowAlertPresentsViaRegisteredSourceWindow() {
        var feedbackCount = 0
        let (manager, _) = makeNotificationManager(state: .active) {
            feedbackCount += 1
        }
        manager.supportsMultipleWindows = true
        manager.registerAgentSelectionHandler(
            for: BackendID(Self.connectionId)
        ) { _, _, _, _ in }

        manager.presentIdleAlert(
            agentId: "agent-1",
            workspaceId: "workspace-1",
            agentName: "Build Agent"
        )

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
            agentId: "agent-1",
            workspaceId: "workspace-1",
            agentName: "Build Agent"
        )

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
            for: BackendID(Self.connectionId)
        ) { _, _, _, _ in }
        manager.conversationOpened(agentId: "agent-1", connectionId: Self.connectionId)

        manager.presentIdleAlert(
            agentId: "agent-1",
            workspaceId: "workspace-1",
            agentName: "Build Agent"
        )

        #expect(feedbackCount == 1)
        #expect(manager.currentToast == nil)
    }

    // MARK: - Window-emitted feedback sound (visionOS spatial audio)

    @Test @MainActor func windowEmittingAlertPublishesEventInsteadOfGlobalFeedback() {
        // visionOS: the manager publishes a per-backend feedback request
        // for the source window to emit spatially instead of playing the
        // global (non-spatial) sound.
        var feedbackCount = 0
        let (manager, center) = makeNotificationManager(
            state: .active,
            windowEmitsFeedbackSound: true
        ) { feedbackCount += 1 }
        manager.supportsMultipleWindows = true
        manager.registerAgentSelectionHandler(
            for: BackendID(Self.connectionId)
        ) { _, _, _, _ in }

        manager.presentIdleAlert(
            agentId: "agent-1",
            workspaceId: "workspace-1",
            agentName: "Build Agent"
        )

        #expect(feedbackCount == 0)
        #expect(manager.windowFeedbackEvent?.sourceBackendID == BackendID(Self.connectionId))
        #expect(manager.currentToast?.agentId == "agent-1")
        #expect(center.requests.isEmpty)
    }

    @Test @MainActor func windowEmittingSuppressedAlertStillPublishesEvent() {
        // The suppression downgrade (open conversation → feedback only)
        // still emits the sound from the source window, with no toast.
        var feedbackCount = 0
        let (manager, _) = makeNotificationManager(
            state: .active,
            windowEmitsFeedbackSound: true
        ) { feedbackCount += 1 }
        manager.supportsMultipleWindows = true
        manager.registerAgentSelectionHandler(
            for: BackendID(Self.connectionId)
        ) { _, _, _, _ in }
        manager.conversationOpened(agentId: "agent-1", connectionId: Self.connectionId)

        manager.presentIdleAlert(
            agentId: "agent-1",
            workspaceId: "workspace-1",
            agentName: "Build Agent"
        )

        #expect(feedbackCount == 0)
        #expect(manager.windowFeedbackEvent?.sourceBackendID == BackendID(Self.connectionId))
        #expect(manager.currentToast == nil)
    }

    @Test @MainActor func repeatWindowEmittedAlertsPublishDistinctEventIds() {
        // Each request carries a fresh id so a window's onChange re-fires
        // for back-to-back alerts from the same backend.
        let (manager, _) = makeNotificationManager(
            state: .active,
            windowEmitsFeedbackSound: true
        )
        manager.supportsMultipleWindows = true
        manager.registerAgentSelectionHandler(
            for: BackendID(Self.connectionId)
        ) { _, _, _, _ in }

        manager.presentIdleAlert(
            agentId: "agent-1",
            workspaceId: "workspace-1",
            agentName: "Build Agent"
        )
        let first = manager.windowFeedbackEvent
        manager.presentIdleAlert(
            agentId: "agent-2",
            workspaceId: "workspace-2",
            agentName: "Test Agent"
        )

        #expect(first != nil)
        #expect(manager.windowFeedbackEvent != nil)
        #expect(manager.windowFeedbackEvent != first)
    }

    @Test @MainActor func systemSoundPathNeverPublishesWindowEvent() {
        var feedbackCount = 0
        let (manager, center) = makeNotificationManager(state: .active) {
            feedbackCount += 1
        }

        manager.presentIdleAlert(
            agentId: "agent-1",
            workspaceId: "workspace-1",
            agentName: "Build Agent"
        )

        #expect(feedbackCount == 1)
        #expect(manager.windowFeedbackEvent == nil)
        #expect(center.requests.count == 1)
    }
}
