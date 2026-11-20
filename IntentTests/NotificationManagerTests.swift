import Foundation
@testable import Intent
import Testing
import UIKit
import UserNotifications

@MainActor
final class NotificationManagerFakeCenter: LocalNotificationCenter {
    weak var delegate: (any UNUserNotificationCenterDelegate)?
    private(set) var requests: [UNNotificationRequest] = []
    private(set) var removedNotificationIdentifiers: [[String]] = []
    var authorizationStatus: UNAuthorizationStatus = .authorized
    var addError: (any Error)?
    var soundEnabled = true

    func soundIsEnabled() -> Bool { soundEnabled && authorizationStatus == .authorized }

    func getAuthorizationStatus(
        completionHandler: @MainActor @Sendable (UNAuthorizationStatus) -> Void
    ) {
        completionHandler(authorizationStatus)
    }

    func requestAuthorization(
        options _: UNAuthorizationOptions,
        completionHandler: @Sendable (Bool, (any Error)?) -> Void
    ) {
        completionHandler(true, nil)
    }

    func add(
        _ request: UNNotificationRequest,
        withCompletionHandler completionHandler: (@Sendable ((any Error)?) -> Void)?
    ) {
        requests.append(request)
        completionHandler?(addError)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedNotificationIdentifiers.append(identifiers)
    }
}

@Suite("NotificationManager idle-alert suppression")
@MainActor
struct NotificationManagerTests {
    static let connectionId = UUID(uuid: (
        0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11,
        0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11
    ))
    static let pinnedBackend = BackendID(UUID(uuid: (
        0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22,
        0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22
    )))

    func makeNotificationManager(
        state: UIApplication.State,
        windowEmitsFeedbackSound: Bool = false,
        relayDeliversAlerts: Bool = false,
        feedback: @escaping () -> Void = {}
    ) -> (NotificationManager, NotificationManagerFakeCenter) {
        let center = NotificationManagerFakeCenter()
        let service = LocalNotificationService(center: center, playForegroundSound: {}, outputVolume: { 1 })
        let manager = NotificationManager(
            localNotificationService: service,
            applicationState: { state },
            activeConnectionId: { Self.connectionId },
            presentFeedback: feedback,
            windowEmitsFeedbackSound: windowEmitsFeedbackSound,
            relayDeliversAlerts: { _ in relayDeliversAlerts },
            registerEvents: false
        )
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
        waitingForAgentIds: [String] = [],
        notificationsMuted: Bool = false
    ) -> AgentSession {
        AgentSession(
            id: id,
            name: "Agent \(id)",
            status: status,
            isBackground: isBackground,
            isStreaming: isStreaming,
            isProcessing: isProcessing,
            isResponding: isResponding,
            isWaitingForOtherAgents: isWaitingForOtherAgents,
            waitingForAgentIds: waitingForAgentIds,
            createdAt: nil,
            updatedAt: nil,
            lastActivity: nil,
            lastAgentResponse: nil,
            lastUserMessage: nil,
            lastMessageRole: nil,
            digest: nil,
            specialist: nil,
            createdByAgentId: nil,
            attentionRequestKind: nil,
            attentionRequestReason: nil,
            attentionRequestTimestamp: nil,
            notificationsMuted: notificationsMuted
        )
    }

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
        let agents = [makeAgent(id: "idle", isStreaming: true, isResponding: true)]
        #expect(NotificationManager.shouldSuppressIdleAlert(idleAgentId: "idle", agents: agents) == false)
    }

    @Test func backgroundMetadataFallbackSuppresses() {
        let agents = [makeAgent(id: "bg", isBackground: true)]
        #expect(NotificationManager.shouldSuppressIdleAlert(idleAgentId: "bg", agents: agents) == true)
    }

    @Test func mutedIdleAgentSuppresses() {
        let agents = [makeAgent(id: "muted", notificationsMuted: true), makeAgent(id: "other")]
        #expect(NotificationManager.shouldSuppressIdleAlert(idleAgentId: "muted", agents: agents) == true)
    }

    @Test func mutedOtherAgentDoesNotSuppressIdleAgent() {
        let agents = [makeAgent(id: "idle"), makeAgent(id: "other", notificationsMuted: true)]
        #expect(NotificationManager.shouldSuppressIdleAlert(idleAgentId: "idle", agents: agents) == false)
    }

    @Test func mutedActiveOtherAgentDoesNotSuppressIdleAgent() {
        let agents = [
            makeAgent(id: "idle"),
            makeAgent(id: "muted-active", isStreaming: true, notificationsMuted: true)
        ]
        #expect(NotificationManager.shouldSuppressIdleAlert(idleAgentId: "idle", agents: agents) == false)
    }

    @Test func unmutedActiveOtherAgentStillSuppressesIdleAgent() {
        let agents = [
            makeAgent(id: "idle"),
            makeAgent(id: "muted-active", isStreaming: true, notificationsMuted: true),
            makeAgent(id: "loud-active", isStreaming: true)
        ]
        #expect(NotificationManager.shouldSuppressIdleAlert(idleAgentId: "idle", agents: agents) == true)
    }

    @Test func soleQuietAgentAlerts() {
        let agents = [makeAgent(id: "idle"), makeAgent(id: "other")]
        #expect(NotificationManager.shouldSuppressIdleAlert(idleAgentId: "idle", agents: agents) == false)
    }

    @Test func agentListFailureFailsOpen() {
        #expect(NotificationManager.shouldSuppressIdleAlert(idleAgentId: "idle", agentList: .unavailable) == false)
    }

    @Test func idleAgentMissingFromListAlertsWhenOthersQuiet() {
        let agents = [makeAgent(id: "other")]
        #expect(NotificationManager.shouldSuppressIdleAlert(idleAgentId: "gone", agents: agents) == false)
    }

    @Test func backgroundEventFlagSkips() {
        #expect(NotificationManager.shouldSkipIdleEventFastPath(["isBackground": true]) == true)
    }

    @Test func mutedEventFlagSkips() {
        #expect(NotificationManager.shouldSkipIdleEventFastPath(["notificationsMuted": true]) == true)
    }

    @Test func explicitlyUnmutedEventFlagDoesNotSkip() {
        #expect(NotificationManager.shouldSkipIdleEventFastPath(["notificationsMuted": false]) == false)
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
}

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

    @Test func chimeIsQuietWithClickFreeEdges() {
        let samples = NotificationChime.chimeSamples()
        let peak = samples.map { abs(Int($0)) }.max() ?? 0
        #expect(peak > 500)
        #expect(peak < 6000)
        #expect(samples.first == 0)
        #expect(samples.last == 0)
        let largestStep = zip(samples, samples.dropFirst()).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(largestStep < 500)
    }

    @Test func fileURLIsCreatedOnceAndStable() throws {
        let first = try #require(NotificationChime.fileURL())
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(NotificationChime.fileURL() == first)
    }
}
