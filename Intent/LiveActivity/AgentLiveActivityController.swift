#if os(iOS)
import ActivityKit
import Observation
import UIKit

@MainActor
final class AgentLiveActivityController {
    static let shared = AgentLiveActivityController()
    static let enabledKey = "liveActivitiesEnabled"

    private static let publishDelay: Duration = .seconds(1)
    private static let staleAfter: TimeInterval = 1800

    private var stores: [BackendID: WorkspaceStore] = [:]
    private var activityID: String?
    private var publishTask: Task<Void, Never>?
    private var dismissedRunningKeys: Set<String> = []
    private var activeObserver: NSObjectProtocol?
    private var isRelayDriven = RelayLinkState.load(from: .standard).isRelayDriven

    private init() {
        let existing = isRelayDriven ? [] : Activity<AgentActivityAttributes>.activities
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

    func setEnabled(_ enabled: Bool) {
        guard !enabled else {
            schedulePublish()
            return
        }
        dismissedRunningKeys = []
        if isRelayDriven {
            Task { await Self.endAll() }
            return
        }
        guard let id = activityID else { return }
        activityID = nil
        Task { await Self.end(id: id, content: nil, policy: .immediate) }
    }

    func setRelayDriven(_ driven: Bool) {
        guard driven != isRelayDriven else { return }
        isRelayDriven = driven
        publishTask?.cancel()
        publishTask = nil
        dismissedRunningKeys = []
        if driven {
            guard let id = activityID else { return }
            activityID = nil
            Task { await Self.end(id: id, content: nil, policy: .immediate) }
        } else {
            activityID = Activity<AgentActivityAttributes>.activities.first?.id
            schedulePublish()
        }
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
        guard !isRelayDriven, publishTask == nil else { return }
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: Self.publishDelay)
            guard let self, !Task.isCancelled else { return }
            publishTask = nil
            await publish()
        }
    }

    private func publish() async {
        guard isEnabled, !isRelayDriven else { return }
        let entries = stores
            .sorted { $0.key.connectionID.uuidString < $1.key.connectionID.uuidString }
            .flatMap { backendID, store in
                store.workspaces.map { AgentActivityContent.Entry(connectionId: backendID.connectionID, workspace: $0) }
            }
        let result = AgentActivityContent.make(from: entries, now: .now)
        let content = ActivityContent(state: Self.demoState(result.state), staleDate: .now.addingTimeInterval(Self.staleAfter))

        let activityState = activityID.flatMap(Self.state(id:))
        if activityState == .dismissed {
            dismissedRunningKeys = result.runningKeys
        }
        guard let id = activityID, activityState == .active || activityState == .stale else {
            activityID = nil
            start(content, running: result.runningKeys)
            return
        }
        if result.runningKeys.isEmpty {
            guard isSettled else { return }
            activityID = nil
            await Self.end(id: id, content: nil, policy: .immediate)
            return
        }
        await Self.update(id: id, content: content)
    }

    private static func demoState(_ state: AgentActivityAttributes.ContentState) -> AgentActivityAttributes.ContentState {
        #if DEBUG
        let options = LaunchOptions.current
        let kind: AgentActivityNoticeKind? = options.contains("--demo-live-activity-needs-input") ? .needsAttention
            : options.contains("--demo-live-activity-review") ? .reviewRequired : nil
        if DemoMode.isEnabled, options.contains("--demo-live-activity-finished-running"), let row = state.rows.first {
            var mixed = state
            mixed.finished = AgentActivityRow(
                connectionId: row.connectionId,
                workspaceId: "demo-finished",
                title: "Docs pass",
                detail: "README and setup guide updated for the new relay.",
                agentId: nil,
                agentName: "Writer",
                kind: kind
            )
            return mixed
        }
        if DemoMode.isEnabled, options.contains("--demo-live-activity-finished"), let row = state.rows.first {
            var finished = state
            finished.rows = []
            finished.runningCount = 0
            finished.finished = AgentActivityRow(
                connectionId: row.connectionId,
                workspaceId: row.workspaceId,
                title: row.title,
                detail: row.detail ?? "Reconnect storm fixed: retries now back off with jitter and the flaky test passes.",
                agentId: row.agentId,
                agentName: row.agentName,
                kind: kind
            )
            return finished
        }
        #endif
        return state
    }

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

    nonisolated private static func endAll() async {
        for activity in Activity<AgentActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func start(_ content: ActivityContent<AgentActivityAttributes.ContentState>, running: Set<String>) {
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

    private var isSettled: Bool {
        !stores.isEmpty && stores.values.allSatisfy { $0.lastUpdated != nil }
    }
}
#endif
