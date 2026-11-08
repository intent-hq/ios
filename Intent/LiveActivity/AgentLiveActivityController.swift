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

    private static let publishDelay: Duration = .seconds(1)
    private static let staleAfter: TimeInterval = 30 * 60

    private var stores: [BackendID: WorkspaceStore] = [:]
    private var tracker = AgentActivityTracker()
    private var activity: Activity<AgentActivityAttributes>?
    private var publishTask: Task<Void, Never>?
    /// Running workspaces when the user dismissed the activity; a new one
    /// starts only when another workspace begins running.
    private var dismissedRunningKeys: Set<String> = []
    private var activeObserver: NSObjectProtocol?

    private init() {
        let existing = Activity<AgentActivityAttributes>.activities
        activity = existing.first
        for stale in existing.dropFirst() {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
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
            self.publishTask = nil
            await self.publish()
        }
    }

    private func publish() async {
        let entries = stores
            .sorted { $0.key.connectionID.uuidString < $1.key.connectionID.uuidString }
            .flatMap { backendID, store in
                store.workspaces.map { AgentActivityTracker.Entry(connectionId: backendID.connectionID, workspace: $0) }
            }
        let state = tracker.content(for: entries, now: .now)
        let content = ActivityContent(state: state, staleDate: .now.addingTimeInterval(Self.staleAfter))

        if let activity, activity.activityState == .dismissed {
            dismissedRunningKeys = tracker.runningKeys
            self.activity = nil
        }

        guard let activity, [.active, .stale].contains(activity.activityState) else {
            self.activity = nil
            start(content)
            return
        }
        if state.runningCount == 0 && state.needsYouCount == 0 {
            guard isSettled else { return }
            self.activity = nil
            tracker.reset()
            let policy: ActivityUIDismissalPolicy = state.rows.isEmpty
                ? .immediate
                : .after(.now.addingTimeInterval(AgentActivityTracker.settledRetention))
            await activity.end(content, dismissalPolicy: policy)
            return
        }
        await activity.update(content)
    }

    private func start(_ content: ActivityContent<AgentActivityAttributes.ContentState>) {
        let running = tracker.runningKeys
        dismissedRunningKeys.formIntersection(running)
        guard !running.isEmpty, !running.isSubset(of: dismissedRunningKeys),
              UIApplication.shared.applicationState == .active,
              ActivityAuthorizationInfo().areActivitiesEnabled
        else { return }
        do {
            activity = try Activity.request(attributes: AgentActivityAttributes(), content: content)
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
