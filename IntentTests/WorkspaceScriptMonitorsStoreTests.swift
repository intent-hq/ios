import Foundation
@testable import Intent
import Observation
import Synchronization
import Testing

@MainActor
struct WorkspaceScriptMonitorsStoreTests {
    func monitor(_ id: String = "monitor-1", workspace: String = "ws-1", name: String = "Build") -> [String: Any] {
        [
            "monitorId": id, "workspaceId": workspace, "agentId": "agent-1", "scriptId": "script-1",
            "runId": "run-1", "scriptName": name, "mode": "command", "state": "active",
            "createdAt": "2026-10-17T01:00:00Z", "expiresAt": "2026-10-17T02:00:00Z"
        ]
    }

    func page(_ rows: [[String: Any]], cursor: String? = nil) -> [String: Any] {
        var value: [String: Any] = ["view": "summary", "monitors": rows]
        if let cursor { value["nextCursor"] = cursor }
        return value
    }

    func event(_ store: WorkspaceScriptMonitorsStore, _ type: String, _ row: [String: Any]) {
        store.handleEvent("subscription.event", params: [
            "event": [
                "type": "scriptMonitor:\(type)", "workspaceId": row["workspaceId"] as? String ?? "",
                "data": ["monitor": row]
            ]
        ])
    }

    func fake() -> FakeConnectionManager {
        let fake = FakeConnectionManager()
        fake.connectionState = .connected
        fake.responseMap["events.subscribe"] = ["subscriptionId": "script-feed"]
        fake.responseMap["events.unsubscribe"] = [:] as [String: Any]
        fake.responseMap["scriptMonitor.list"] = page([monitor()])
        return fake
    }

    @Test func sharedLeaseWaitsForAckAndLoadsOnlyOneSummaryPage() async throws {
        let fake = fake()
        let store = WorkspaceScriptMonitorsStore(connection: fake) { true }
        let first = store.retain(workspaceId: "ws-1")
        let second = store.retain(workspaceId: "ws-1")
        fake.pendingMethods = ["events.subscribe"]
        let load = Task { await store.load(workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("events.subscribe")
        #expect(fake.paramsForMethod("scriptMonitor.list").isEmpty)
        let other = Task { await store.load(workspaceId: "ws-1") }
        fake.resolvePending("events.subscribe", with: ["subscriptionId": "script-feed"])
        await load.value
        await other.value
        let params = try #require(fake.paramsForMethod("scriptMonitor.list").first)
        #expect(params["view"] as? String == "summary")
        #expect(params["state"] as? String == "active")
        #expect(params["limit"] as? Int == 100)
        #expect(fake.paramsForMethod("scriptMonitor.list").count == 1)
        #expect(fake.paramsForMethod("scriptMonitor.get").isEmpty)
        #expect(store.rows(for: "ws-1").count == 1)
        store.release(workspaceId: "ws-1", consumer: first)
        #expect(fake.paramsForMethod("events.unsubscribe").isEmpty)
        await store.release(workspaceId: "ws-1", consumer: second)?.value
        #expect(fake.paramsForMethod("events.unsubscribe").count == 1)
    }

    @Test func terminalEventWinsAgainstSeedAndDelayedRegistration() async throws {
        let fake = fake()
        fake.pendingMethods = ["scriptMonitor.list"]
        let store = WorkspaceScriptMonitorsStore(connection: fake) { true }
        store.retain(workspaceId: "ws-1")
        let load = Task { await store.load(workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("scriptMonitor.list")
        event(store, "completed", monitor())
        event(store, "registered", monitor())
        fake.resolvePending("scriptMonitor.list", with: page([monitor()]))
        await load.value
        #expect(store.rows(for: "ws-1").isEmpty)
        #expect(fake.paramsForMethod("scriptMonitor.list").count == 1)
    }

    @Test func explicitPagePreservesRowsAndCursorOnFailure() async {
        let fake = fake()
        fake.responseMap["scriptMonitor.list"] = page([monitor()], cursor: "opaque")
        let store = WorkspaceScriptMonitorsStore(connection: fake) { true }
        store.retain(workspaceId: "ws-1")
        await store.load(workspaceId: "ws-1")
        #expect(fake.paramsForMethod("scriptMonitor.list").count == 1)
        fake.errorMap["scriptMonitor.list"] = URLError(.timedOut)
        await store.loadMore(workspaceId: "ws-1")
        #expect(store.rows(for: "ws-1").count == 1)
        #expect(store.nextCursor(for: "ws-1") == "opaque")
        #expect(store.error(for: "ws-1") != nil)
        fake.errorMap = [:]
        fake.responseMap["scriptMonitor.list"] = page([monitor("monitor-2")])
        await store.loadMore(workspaceId: "ws-1")
        #expect(store.rows(for: "ws-1").count == 2)
        #expect(store.nextCursor(for: "ws-1") == nil)
        #expect(fake.paramsForMethod("scriptMonitor.list").last?["cursor"] as? String == "opaque")
    }

    @Test func sameIdentityTextChangeNotifiesObservation() async {
        let fake = fake()
        let store = WorkspaceScriptMonitorsStore(connection: fake) { true }
        store.retain(workspaceId: "ws-1")
        await store.load(workspaceId: "ws-1")
        let observed = Mutex(false)
        withObservationTracking { _ = store.rows(for: "ws-1").first?.scriptName } onChange: {
            observed.withLock { $0 = true }
        }
        event(store, "registered", monitor(name: "Renamed build"))
        #expect(observed.withLock { $0 })
        #expect(store.rows(for: "ws-1").first?.scriptName == "Renamed build")
    }

    @Test func unsupportedConnectionDoesNotSubscribeOrRead() async {
        let fake = fake()
        let store = WorkspaceScriptMonitorsStore(connection: fake) { false }
        store.retain(workspaceId: "ws-1")
        await store.load(workspaceId: "ws-1")
        await store.loadMore(workspaceId: "ws-1")
        #expect(fake.requestLog.isEmpty)
        #expect(!store.isSupported)
    }
}
