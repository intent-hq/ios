#if os(iOS)
import ActivityKit
import Observation
import UIKit

/// Keeps one Live Activity in step with running agents on every live backend.
///
/// The app drives every update, so the activity is current while the app runs
/// (foreground or its background grace period) and marked stale after.
@MainActor
final class AgentLiveActivityController {
    static let shared = AgentLiveActivityController()
    /// User preference, written by the Settings toggle. Defaults to on.
    static let enabledKey = "liveActivitiesEnabled"

    private static let publishDelay: Duration = .seconds(1)
    private static let staleAfter: TimeInterval = 30 * 60

    private var stores: [BackendID: WorkspaceStore] = [:]
    private var tracker = AgentActivityTracker()
    private var activityID: String?
    private var publishTask: Task<Void, Never>?
    /// Running workspaces when the user dismissed the activity; a new one
    /// starts only when another workspace begins running.
    private var dismissedRunningKeys: Set<String> = []
    private var activeObserver: NSObjectProtocol?

    private init() {
        let existing = Activity<AgentActivityAttributes>.activities
        activityID = existing.first?.id
        for extra in existing.dropFirst() {
            let id = extra.id
            Task { await Self.end(id: id, content: nil, policy: .immediate) }
        }
        if !isEnabled { setEnabled(false) }
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.schedulePublish() }
        }
    }

    func attach(_ session: BackendSession) {
        guard let backendID = session.backendID else { return }
        stores[backendID] = session.workspaceStore
        observe(session.workspaceStore, for: backendID)
        schedulePublish()
    }

    /// Turning off ends the current activity at once; turning on starts one
    /// when an agent is running.
    func setEnabled(_ enabled: Bool) {
        guard !enabled else {
            schedulePublish()
            return
        }
        tracker.reset()
        dismissedRunningKeys = []
        guard let id = activityID else { return }
        activityID = nil
        Task { await Self.end(id: id, content: nil, policy: .immediate) }
    }

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func detach(_ backendID: BackendID) {
        guard stores.removeValue(forKey: backendID) != nil else { return }
        schedulePublish()
    }

    private func observe(_ store: WorkspaceStore, for backendID: BackendID) {
        withObservationTracking {
            _ = store.workspaces
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.stores[backendID] === store else { return }
                self.observe(store, for: backendID)
                self.schedulePublish()
            }
        }
    }

    private func schedulePublish() {
        guard publishTask == nil else { return }
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: Self.publishDelay)
            guard let self, !Task.isCancelled else { return }
            publishTask = nil
            await publish()
        }
    }

    private func publish() async {
        guard isEnabled else { return }
        let entries = stores
            .sorted { $0.key.connectionID.uuidString < $1.key.connectionID.uuidString }
            .flatMap { backendID, store in
                store.workspaces.map { AgentActivityTracker.Entry(connectionId: backendID.connectionID, workspace: $0) }
            }
        let state = tracker.content(for: entries, now: .now)
        let content = ActivityContent(state: state, staleDate: .now.addingTimeInterval(Self.staleAfter))

        let activityState = activityID.flatMap(Self.state(id:))
        if activityState == .dismissed {
            dismissedRunningKeys = tracker.runningKeys
        }
        guard let id = activityID, activityState == .active || activityState == .stale else {
            activityID = nil
            start(content)
            return
        }
        if state.runningCount == 0, state.needsYouCount == 0 {
            guard isSettled else { return }
            activityID = nil
            tracker.reset()
            let policy: ActivityUIDismissalPolicy = state.rows.isEmpty
                ? .immediate
                : .after(.now.addingTimeInterval(AgentActivityTracker.settledRetention))
            await Self.end(id: id, content: content, policy: policy)
            return
        }
        await Self.update(id: id, content: content)
    }

    // Activities are not Sendable: each helper looks one up and uses it
    // without leaving its own isolation domain.
    nonisolated private static func state(id: String) -> ActivityState? {
        Activity<AgentActivityAttributes>.activities.first { $0.id == id }?.activityState
    }

    nonisolated private static func update(
        id: String,
        content: ActivityContent<AgentActivityAttributes.ContentState>
    ) async {
        await Activity<AgentActivityAttributes>.activities.first { $0.id == id }?.update(content)
    }

    nonisolated private static func end(
        id: String,
        content: ActivityContent<AgentActivityAttributes.ContentState>?,
        policy: ActivityUIDismissalPolicy
    ) async {
        await Activity<AgentActivityAttributes>.activities.first { $0.id == id }?
            .end(content, dismissalPolicy: policy)
    }

    private func start(_ content: ActivityContent<AgentActivityAttributes.ContentState>) {
        let running = tracker.runningKeys
        dismissedRunningKeys.formIntersection(running)
        guard !running.isEmpty, !running.isSubset(of: dismissedRunningKeys),
              UIApplication.shared.applicationState == .active,
              ActivityAuthorizationInfo().areActivitiesEnabled
        else { return }
        do {
            activityID = try Activity.request(attributes: AgentActivityAttributes(), content: content).id
            dismissedRunningKeys = []
        } catch {
            AppLog.notifications.warning("[AgentLiveActivity] Could not start: \(error)")
        }
    }

    /// Every backend has loaded its workspaces, so an empty result is real
    /// rather than a launch still connecting.
    private var isSettled: Bool {
        !stores.isEmpty && stores.values.allSatisfy { $0.lastUpdated != nil }
    }
}
#endif
