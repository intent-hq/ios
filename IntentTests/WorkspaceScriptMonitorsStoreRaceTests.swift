import Foundation
@testable import Intent
import Testing

extension WorkspaceScriptMonitorsStoreTests {
    @Test func allTerminalEventsRemoveSummaryAndInvalidateSelectedGet() async throws {
        for type in ["completed", "triggered", "expired", "cancelled"] {
            let fake = fake()
            let store = WorkspaceScriptMonitorsStore(connection: fake) { true }
            store.retain(workspaceId: "ws-1")
            await store.load(workspaceId: "ws-1")
            let selection = store.select(workspaceId: "ws-1", monitorId: "monitor-1")
            fake.pendingMethods = ["scriptMonitor.get"]
            let read = Task { await store.loadDetail(selection: selection) }
            try await fake.waitForPendingRequests("scriptMonitor.get")
            event(store, type, monitor())
            fake.resolvePending("scriptMonitor.get", with: monitor())
            await read.value
            #expect(store.rows(for: "ws-1").isEmpty)
            #expect(store.detailState(selection: selection) == .unavailable)
            #expect(fake.paramsForMethod("scriptMonitor.list").count == 1)
        }
    }

    @Test func terminalDuringNextPageCannotResurrectRow() async throws {
        let fake = fake()
        fake.responseMap["scriptMonitor.list"] = page([monitor()], cursor: "older")
        let store = WorkspaceScriptMonitorsStore(connection: fake) { true }
        store.retain(workspaceId: "ws-1")
        await store.load(workspaceId: "ws-1")
        fake.pendingMethods = ["scriptMonitor.list"]
        let next = Task { await store.loadMore(workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("scriptMonitor.list")
        event(store, "triggered", monitor("monitor-2"))
        event(store, "registered", monitor("monitor-2"))
        fake.resolvePending("scriptMonitor.list", with: page([monitor("monitor-2")]))
        await next.value
        #expect(store.rows(for: "ws-1").map(\.monitorId) == ["monitor-1"])
        #expect(fake.paramsForMethod("scriptMonitor.list").count == 2)
    }

    @Test func detailsAreLazySharedPerSelectionAndFullPatternStaysOutOfRows() async {
        let fake = fake()
        var full = monitor()
        full["outputPattern"] = "^Ready [a-z]+$"
        fake.responseMap["scriptMonitor.get"] = full
        let store = WorkspaceScriptMonitorsStore(connection: fake) { true }
        store.retain(workspaceId: "ws-1")
        await store.load(workspaceId: "ws-1")
        #expect(fake.paramsForMethod("scriptMonitor.get").isEmpty)
        let selection = store.select(workspaceId: "ws-1", monitorId: "monitor-1")
        await store.loadDetail(selection: selection)
        await store.loadDetail(selection: selection)
        guard case .loaded(let detail) = store.detailState(selection: selection) else {
            Issue.record("Selected watch detail did not load")
            return
        }
        #expect(detail.outputPattern == "^Ready [a-z]+$")
        #expect(fake.paramsForMethod("scriptMonitor.get").count == 1)
        #expect(fake.paramsForMethod("script.get").isEmpty)
        #expect(fake.paramsForMethod("script.output").isEmpty)
        store.deselect(selection: selection)
        #expect(store.detailState(selection: selection) == .unavailable)
    }

    @Test func separateHostsAndWorkspacesNeverShareSameID() async {
        let first = fake()
        let second = fake()
        second.responseMap["scriptMonitor.list"] = page([monitor(name: "Second host")])
        let store = WorkspaceScriptMonitorsStore(connection: first) { true }
        let other = WorkspaceScriptMonitorsStore(connection: second) { true }
        store.retain(workspaceId: "ws-1")
        other.retain(workspaceId: "ws-1")
        await store.load(workspaceId: "ws-1")
        await other.load(workspaceId: "ws-1")
        first.responseMap["scriptMonitor.list"] = page([monitor(workspace: "ws-2", name: "Second workspace")])
        store.retain(workspaceId: "ws-2")
        await store.load(workspaceId: "ws-2")
        event(store, "cancelled", monitor())
        #expect(store.rows(for: "ws-1").isEmpty)
        #expect(store.rows(for: "ws-2").first?.scriptName == "Second workspace")
        #expect(other.rows(for: "ws-1").first?.scriptName == "Second host")
    }

    @Test func unsupportedReplyDisablesUntilReconnectWithoutFullFallback() async {
        let fake = fake()
        fake.responseMap["scriptMonitor.list"] = ["monitors": []] as [String: Any]
        let store = WorkspaceScriptMonitorsStore(connection: fake) { true }
        store.retain(workspaceId: "ws-1")
        await store.load(workspaceId: "ws-1")
        #expect(!store.isSupported)
        await store.refresh(workspaceId: "ws-1")
        #expect(fake.paramsForMethod("scriptMonitor.list").count == 1)
        #expect(fake.paramsForMethod("scriptMonitor.list").allSatisfy { $0["view"] as? String == "summary" })
    }

    @Test func reconnectReplacesPagesAndRevalidatesOffPageSelection() async throws {
        let fake = fake()
        let store = WorkspaceScriptMonitorsStore(connection: fake) { true }
        store.retain(workspaceId: "ws-1")
        await store.load(workspaceId: "ws-1")
        let selection = store.select(workspaceId: "ws-1", monitorId: "monitor-1")
        fake.responseMap["scriptMonitor.get"] = monitor()
        await store.loadDetail(selection: selection)
        fake.connectionState = .disconnected
        #expect(store.rows(for: "ws-1").isEmpty)
        #expect(store.detailState(selection: selection) == .unavailable)
        fake.responseMap["scriptMonitor.list"] = page([monitor("monitor-new")], cursor: "new-page")
        fake.connectionState = .connected
        try await waitUntil("fresh page and off-page detail") {
            store.rows(for: "ws-1").map(\.monitorId) == ["monitor-new"] && fake.paramsForMethod("scriptMonitor.get").count == 2
        }
        try await waitUntil("selected detail revalidated") {
            if case .loaded = store.detailState(selection: selection) { return true }
            return false
        }
        #expect(store.nextCursor(for: "ws-1") == "new-page")
    }
}

extension WorkspaceScriptMonitorsStoreTests {
    @Test func wrongRunOrWorkspaceTerminalCannotRemoveAnotherWatch() async {
        let fake = fake()
        let store = WorkspaceScriptMonitorsStore(connection: fake) { true }
        store.retain(workspaceId: "ws-1")
        await store.load(workspaceId: "ws-1")
        var otherRun = monitor()
        otherRun["runId"] = "other-run"
        event(store, "cancelled", otherRun)
        #expect(store.rows(for: "ws-1").count == 1)
        store.handleEvent("event", params: [
            "type": "scriptMonitor:cancelled", "workspaceId": "ws-foreign",
            "data": ["workspaceId": "ws-1", "monitor": monitor()]
        ])
        #expect(store.rows(for: "ws-1").count == 1)
        #expect(fake.paramsForMethod("scriptMonitor.list").count == 1)
    }

    @Test func registrationDuringGetInvalidatesStaleDetailAndUpdatesSelectedText() async throws {
        let fake = fake()
        let store = WorkspaceScriptMonitorsStore(connection: fake) { true }
        store.retain(workspaceId: "ws-1")
        await store.load(workspaceId: "ws-1")
        let selected = store.select(workspaceId: "ws-1", monitorId: "monitor-1")
        fake.pendingMethods = ["scriptMonitor.get"]
        let detail = Task { await store.loadDetail(selection: selected) }
        try await fake.waitForPendingRequests("scriptMonitor.get")
        event(store, "registered", monitor(name: "New script title"))
        fake.resolvePending("scriptMonitor.get", with: monitor())
        await detail.value
        #expect(store.detailSummary(selection: selected)?.scriptName == "New script title")
        guard case .failed = store.detailState(selection: selected) else {
            Issue.record("Stale detail must require an explicit retry")
            return
        }
        #expect(fake.paramsForMethod("scriptMonitor.list").count == 1)
    }
}
