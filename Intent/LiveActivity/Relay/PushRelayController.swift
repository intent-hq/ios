#if os(iOS)
import ActivityKit
import Combine
import Foundation
import UIKit

/// Links each connected machine to the push relay and keeps the relay's copy
/// of this device current: APNs tokens, Live Activity tokens and the Live
/// Activities switch. With any machine linked, the relay drives the Live
/// Activity and `AgentLiveActivityController` stands down (D7).
@MainActor
final class PushRelayController {
    static let shared = PushRelayController()

    private static let methodNotFoundCode = -32_601
    private static let relayNotFoundStatus = 404
    private static let snapshotStaleAfter: TimeInterval = 600

    private let defaults: UserDefaults = .standard
    private var state: RelayLinkState
    private var key: RelayDeviceKey?
    private var sessions: [UUID: BackendSession] = [:]
    private var connectionObservers: [UUID: AnyCancellable] = [:]
    /// Machines that could not link; cleared each time the app becomes active.
    private var declined: Set<UUID> = []
    private var linking: Set<UUID> = []
    /// Machines forgotten this run; a registration that finishes later is undone.
    private var removedConnections: Set<UUID> = []
    /// Tail of the relay registration and unlink chain.
    private var relayOperations: Task<Void, Never>?
    private var pushToken: String?
    private var pushToStartToken: String?
    /// The Live Activity whose push token the relay holds.
    private var liveActivity: (id: String, token: String)?
    private var observedActivities: Set<String> = []
    private let deviceSync = CoalescedRead()
    private var activeObserver: NSObjectProtocol?

    private init() {
        state = RelayLinkState.load(from: defaults)
    }

    var isRelayDriven: Bool { state.isRelayDriven }

    /// A linked machine's agent alerts come from the relay as remote
    /// notifications, so the app does not post its own for that machine.
    func deliversAlerts(for connectionId: UUID) -> Bool {
        state.link(for: connectionId) != nil
    }

    /// Starts token streams and launch work. Call once at app launch.
    func start() {
        AgentLiveActivityController.shared.setRelayDriven(state.isRelayDriven)
        Task { [weak self] in
            await Self.pushToStartTokens { token in self?.pushToStartTokenChanged(token) }
        }
        Task { [weak self] in
            await Self.activityIDs { id in self?.observeActivity(id: id) }
        }
        for activity in Activity<AgentActivityAttributes>.activities {
            observeActivity(id: activity.id)
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.becameActive() }
        }
    }

    // MARK: - Sessions

    func attach(_ session: BackendSession) {
        guard let connectionId = session.backendID?.connectionID else { return }
        sessions[connectionId] = session
        connectionObservers[connectionId] = session.connection.connectionStatePublisher
            .filter { $0 == .connected }
            .sink { [weak self] _ in
                Task { @MainActor in self?.linkIfNeeded(connectionId) }
            }
    }

    func detach(_ backendID: BackendID) {
        sessions[backendID.connectionID] = nil
        connectionObservers[backendID.connectionID] = nil
    }

    /// The saved connections were removed: revoke their links.
    func connectionsRemoved(_ backendIDs: [BackendID]) {
        for backendID in backendIDs {
            removedConnections.insert(backendID.connectionID)
            Task { await unlink(connectionId: backendID.connectionID) }
        }
    }

    // MARK: - Tokens and preferences

    func deviceTokenChanged(_ token: Data) {
        pushToken = token.hexString
        scheduleDeviceSync()
    }

    /// The Live Activities switch changed.
    func preferencesChanged() {
        scheduleDeviceSync()
        for connectionId in sessions.keys { linkIfNeeded(connectionId) }
    }

    private func pushToStartTokenChanged(_ token: Data) {
        pushToStartToken = token.hexString
        scheduleDeviceSync()
    }

    private var isEnabled: Bool {
        defaults.object(forKey: AgentLiveActivityController.enabledKey) as? Bool ?? true
    }

    private func currentDevice() -> RelayDeviceInfo {
        RelayDeviceInfo(
            bundleId: Bundle.main.bundleIdentifier,
            apsEnvironment: Bundle.main.object(forInfoDictionaryKey: "IntentApsEnvironment") as? String ?? "production",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            osVersion: UIDevice.current.systemVersion,
            pushToken: pushToken ?? state.sentDevice?.pushToken,
            pushToStartToken: pushToStartToken ?? state.sentDevice?.pushToStartToken,
            preferences: RelayDeviceInfo.Preferences(liveActivity: isEnabled)
        )
    }

    private func scheduleDeviceSync() {
        guard deviceSync.invalidate() else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = await deviceSync.run(isCurrent: { true }, pass: { [weak self] _ in await self?.syncDevice() })
            deviceSync.settleScheduled()
        }
    }

    private func syncDevice() async {
        let device = currentDevice()
        guard let patch = state.devicePatch(for: device), let client = makeClient() else { return }
        do {
            try await client.updateDevice(patch)
            state.sentDevice = patch
            state.save(to: defaults)
        } catch {
            AppLog.notifications.warning("[PushRelay] Device update failed: \(error)")
        }
    }

    // MARK: - Live Activity tokens

    private func observeActivity(id: String) {
        guard observedActivities.insert(id).inserted else { return }
        Task { [weak self] in
            await Self.pushTokens(activityID: id) { token in self?.activityTokenChanged(id: id, token: token) }
        }
        Task { [weak self] in
            await Self.waitUntilEnded(activityID: id)
            self?.activityEnded(id: id)
        }
    }

    private func activityTokenChanged(id: String, token: Data) {
        let hex = token.hexString
        guard liveActivity?.id != id || liveActivity?.token != hex else { return }
        liveActivity = (id, hex)
        sendActivityToken(hex)
    }

    private func activityEnded(id: String) {
        observedActivities.remove(id)
        // A newer activity may already hold the relay's token.
        guard liveActivity?.id == id else { return }
        liveActivity = nil
        sendActivityToken(nil)
    }

    private func sendActivityToken(_ token: String?) {
        guard let client = makeClient() else { return }
        Task {
            do {
                try await client.setLiveActivityToken(token)
            } catch {
                AppLog.notifications.warning("[PushRelay] Live Activity token update failed: \(error)")
            }
        }
    }

    // MARK: - Linking

    private func linkIfNeeded(_ connectionId: UUID) {
        guard let session = sessions[connectionId],
              state.shouldLink(
                  connectionId: connectionId,
                  enabled: isEnabled,
                  connected: session.connection.connectionState == .connected,
                  declined: declined
              ),
              linking.insert(connectionId).inserted
        else { return }
        Task {
            defer { linking.remove(connectionId) }
            do {
                try await link(connectionId, over: session.connection)
            } catch {
                declined.insert(connectionId)
                if (error as NSError).code != Self.methodNotFoundCode {
                    AppLog.notifications.warning("[PushRelay] Link failed: \(error)")
                }
            }
        }
    }

    private func link(_ connectionId: UUID, over connection: any SessionConnectionManaging) async throws {
        let response = try await connection.request("push.createLink", params: [:], timeout: ConnectionManager.defaultRequestTimeout)
        guard let result = response as? [String: Any],
              let linkToken = result["linkToken"] as? String,
              let relayURL = (result["relayUrl"] as? String).flatMap(URL.init(string:))
        else { throw RelayClientError.invalidResponse }
        guard state.accepts(relayURL: relayURL) else {
            AppLog.notifications.warning("[PushRelay] Machine uses another relay: \(relayURL)")
            declined.insert(connectionId)
            return
        }
        let client = try makeClient(baseURL: relayURL)
        let device = currentDevice()
        let forgotten = try await serialized { [self] in
            let registration = try await client.register(linkToken: linkToken, connectionId: connectionId, device: device)
            let link = RelayLink(connectionId: connectionId, daemonId: registration.daemonId, relayURL: relayURL)
            guard !removedConnections.contains(connectionId) else {
                state.queueUnlink(link)
                state.save(to: defaults)
                return true
            }
            let wasRelayDriven = state.isRelayDriven
            state.record(link)
            state.sentDevice = device
            state.save(to: defaults)
            if !wasRelayDriven {
                AgentLiveActivityController.shared.setRelayDriven(true)
                if let liveActivity { sendActivityToken(liveActivity.token) }
            }
            return false
        }
        if forgotten { await retryPendingUnlinks() }
    }

    /// Registrations and unlinks reach the relay one at a time, so an unlink
    /// already on the wire cannot revoke the registration that replaced it.
    private func serialized<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = relayOperations
        let task = Task { @MainActor in
            await previous?.value
            return try await operation()
        }
        relayOperations = Task { _ = try? await task.value }
        return try await task.value
    }

    private func unlink(connectionId: UUID) async {
        guard state.link(for: connectionId) != nil else { return }
        state.queueUnlink(connectionId: connectionId)
        state.save(to: defaults)
        if !state.isRelayDriven {
            AgentLiveActivityController.shared.setRelayDriven(false)
        }
        if let connection = sessions[connectionId]?.connection, connection.connectionState == .connected {
            _ = try? await connection.request("push.revokeLink", params: [:], timeout: ConnectionManager.defaultRequestTimeout)
        }
        await retryPendingUnlinks()
    }

    /// Each forgotten link stays queued until the relay confirms it is gone.
    private func retryPendingUnlinks() async {
        try? await serialized { [self] in
            for link in state.pendingUnlinks {
                await sendUnlink(link)
            }
        }
    }

    private func sendUnlink(_ link: RelayLink) async {
        // Re-pairing removes the entry; never revoke the replacement.
        guard state.pendingUnlinks.contains(link),
              let client = try? makeClient(baseURL: link.relayURL)
        else { return }
        do {
            try await client.unlink(daemonId: link.daemonId)
        } catch RelayClientError.status(Self.relayNotFoundStatus, _) {
            // Already gone at the relay.
        } catch {
            AppLog.notifications.warning("[PushRelay] Unlink will retry: \(error)")
            return
        }
        state.unlinkConfirmed(daemonId: link.daemonId)
        state.save(to: defaults)
    }

    // MARK: - Launch and foreground

    private func becameActive() {
        declined = []
        if let saved = PersistenceManager.shared.loadConnectionsWithOutcome().connections {
            for link in state.staleLinks(savedConnectionIds: Set(saved.map(\.id))) {
                Task { await unlink(connectionId: link.connectionId) }
            }
        }
        Task { await retryPendingUnlinks() }
        for connectionId in sessions.keys { linkIfNeeded(connectionId) }
        scheduleDeviceSync()
        Task { await applySnapshot() }
    }

    /// The relay's content can be ahead of a stale card while the app was
    /// closed; show it at once.
    private func applySnapshot() async {
        guard state.isRelayDriven, isEnabled, let client = makeClient() else { return }
        do {
            let snapshot = try await client.snapshot()
            guard snapshot.contentState.runningCount > 0 else {
                // Nothing runs: clear a card the relay's end push did not remove.
                await Self.endAll()
                return
            }
            let content = ActivityContent(
                state: snapshot.contentState,
                staleDate: .now.addingTimeInterval(Self.snapshotStaleAfter)
            )
            await Self.updateAll(content)
        } catch {
            AppLog.notifications.warning("[PushRelay] Snapshot failed: \(error)")
        }
    }

    // MARK: - Relay client

    private func makeClient() -> RelayClient? {
        guard let relayURL = state.relayURL else { return nil }
        return try? makeClient(baseURL: relayURL)
    }

    private func makeClient(baseURL: URL) throws -> RelayClient {
        if key == nil { key = try RelayDeviceKey.loadOrCreate() }
        guard let key else { throw RelayDeviceKey.LoadError.keyCreationFailed }
        return RelayClient(baseURL: baseURL, signer: key)
    }

    // MARK: - ActivityKit streams

    // Activities are not Sendable: each helper iterates off the main actor
    // and hands back only ids and token bytes.
    nonisolated private static func pushToStartTokens(_ handle: @MainActor @Sendable (Data) -> Void) async {
        for await token in Activity<AgentActivityAttributes>.pushToStartTokenUpdates {
            await handle(token)
        }
    }

    nonisolated private static func activityIDs(_ handle: @MainActor @Sendable (String) -> Void) async {
        for await activity in Activity<AgentActivityAttributes>.activityUpdates {
            let id = activity.id
            await handle(id)
        }
    }

    nonisolated private static func pushTokens(activityID: String, _ handle: @MainActor @Sendable (Data) -> Void) async {
        guard let activity = Activity<AgentActivityAttributes>.activities.first(where: { $0.id == activityID }) else { return }
        for await token in activity.pushTokenUpdates {
            await handle(token)
        }
    }

    nonisolated private static func waitUntilEnded(activityID: String) async {
        guard let activity = Activity<AgentActivityAttributes>.activities.first(where: { $0.id == activityID }) else { return }
        for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
            return
        }
    }

    nonisolated private static func endAll() async {
        for activity in Activity<AgentActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    nonisolated private static func updateAll(_ content: ActivityContent<AgentActivityAttributes.ContentState>) async {
        for activity in Activity<AgentActivityAttributes>.activities {
            await activity.update(content)
        }
    }
}

private extension Data {
    /// APNs tokens go to the relay as lowercase hex.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
#endif
