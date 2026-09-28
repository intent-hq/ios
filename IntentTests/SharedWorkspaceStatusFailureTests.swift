import Foundation
@testable import Intent
import Testing

@MainActor
struct SharedWorkspaceStatusFailureTests {
    private typealias Support = WorkspaceStatusTestSupport

    @Test func failedRefreshPreservesRowsAndEventsAndDuplicateConsumersDoNotRetry() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        Support.seedRows(fixture)
        let model = fixture.makeViewModel()
        await model.load()
        let connection = fixture.connection
        connection.pendingMethods = ["hook.list", "prMonitor.list"]
        let hooks = Task { await model.hookStore.refetch() }
        let monitors = Task { await model.monitoredPrStore.refetch() }
        try await connection.waitForPendingRequests("hook.list")
        try await connection.waitForPendingRequests("prMonitor.list")
        Support.event(fixture, type: "hook:run-started", id: "hook-1")
        Support.event(fixture, type: "prMonitor:emitted", id: "monitor-1")
        try await waitUntil("events applied to last good rows") {
            model.hookStore.hooks.first?.state == .running && model.monitoredPrStore.monitors.first?.hasPendingChanges == false
        }
        connection.failPending("hook.list", with: NSError(domain: "fixture", code: 1))
        connection.failPending("prMonitor.list", with: NSError(domain: "fixture", code: 1))
        await hooks.value
        await monitors.value
        #expect(model.hookStore.hooks.first?.state == .running)
        #expect(model.monitoredPrStore.monitors.first?.hasPendingChanges == false)
        #expect(model.hookStore.error != nil && model.monitoredPrStore.error != nil)
        #expect(model.hookStore.isStale && model.monitoredPrStore.isStale)
        let checkpoint = connection.checkpoint
        let other = fixture.makeViewModel()
        await other.load()
        #expect(connection.traffic(since: checkpoint).requests.isEmpty)
        #expect(other.hookStore.error != nil && other.monitoredPrStore.error != nil)
        connection.pendingMethods = []
        await model.hookStore.refetch()
        await model.monitoredPrStore.refetch()
        #expect(other.hookStore.error == nil && other.monitoredPrStore.error == nil)
        #expect(!other.hookStore.isStale && !other.monitoredPrStore.isStale)
    }

    @Test func failedOrMalformedColdSeedIsNotAnEmptySuccessAndRetriesOnlyExplicitly() async {
        for malformed in [false, true] {
            let fixture = ConversationStartupFixture()
            defer { fixture.stop() }
            let connection = fixture.connection
            if malformed {
                connection.responseMap["hook.list"] = ["hooks": [["hookId": "incomplete"]]]
                connection.responseMap["prMonitor.list"] = ["unexpected": []]
            } else {
                connection.errorMap["hook.list"] = NSError(domain: "fixture", code: 1)
                connection.errorMap["prMonitor.list"] = NSError(domain: "fixture", code: 1)
            }
            let model = fixture.makeViewModel()
            await model.load()
            let checkpoint = connection.checkpoint
            let second = fixture.makeViewModel()
            await second.load()
            #expect(connection.traffic(since: checkpoint).requests.isEmpty)
            #expect(model.hookStore.error != nil && model.monitoredPrStore.error != nil)
            connection.errorMap = [:]
            connection.responseMap["hook.list"] = ["hooks": []]
            connection.responseMap["prMonitor.list"] = ["monitors": []]
            await model.hookStore.refetch()
            await model.monitoredPrStore.refetch()
            #expect(second.hookStore.error == nil && second.monitoredPrStore.error == nil)
            #expect(!second.hookStore.isStale && !second.monitoredPrStore.isStale)
            #expect(connection.paramsForMethod("hook.list").count == 2)
            #expect(connection.paramsForMethod("prMonitor.list").count == 2)
        }
    }

    @Test func subscribeFailureKeepsSeedBehindAckAndAnExplicitRetryRecovers() async {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let connection = fixture.connection
        connection.errorMap["events.subscribe"] = NSError(domain: "fixture", code: 1)
        let first = fixture.makeViewModel()
        await first.load()
        #expect(!first.messages.isEmpty && !first.isLoading)
        let second = fixture.makeViewModel()
        await second.load()
        #expect(connection.paramsForMethod("events.subscribe").count == 2)
        #expect(!connection.didCallMethod("hook.list") && !connection.didCallMethod("prMonitor.list"))
        #expect(first.hookStore.error != nil && first.monitoredPrStore.error != nil)
        connection.errorMap = [:]
        await first.hookStore.refetch()
        await first.monitoredPrStore.refetch()
        #expect(connection.paramsForMethod("events.subscribe").count == 4)
        #expect(connection.paramsForMethod("hook.list").count == 1)
        #expect(connection.paramsForMethod("prMonitor.list").count == 1)
        #expect(second.hookStore.error == nil && second.monitoredPrStore.error == nil)
    }

    @Test func agentFilteringAndAllActionsUseTheSharedWorkspace() async {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let connection = fixture.connection
        connection.responseMap["hook.list"] = ["hooks": [Support.hook(), Support.hook("other-hook", agentId: "other")]]
        connection.responseMap["prMonitor.list"] = ["monitors": [Support.monitor(), Support.monitor("other-monitor", agentId: "other")]]
        for method in ["hook.runNow", "hook.cancel", "prMonitor.flush", "prMonitor.cancel"] { connection.responseMap[method] = [:] }
        let model = fixture.makeViewModel()
        await model.load()
        #expect(model.activeAgentHooks.map(\.hookId) == ["hook-1"])
        #expect(model.activeAgentMonitors.map(\.monitorId) == ["monitor-1"])
        #expect(fixture.session.prMonitorsStore.monitors(for: Support.workspace).count == 2)
        await model.hookStore.runNow(hookId: "hook-1")
        await model.hookStore.cancel(hookId: "hook-1")
        for mode in [PrMonitorFlushMode.daemonDefault, .pendingOnly, .refreshFirst] {
            await model.monitoredPrStore.flush(monitorId: "monitor-1", mode: mode)
        }
        await model.monitoredPrStore.cancel(monitorId: "monitor-1")
        let flushes = connection.paramsForMethod("prMonitor.flush")
        #expect(flushes.count == 3 && flushes[0]["check"] == nil)
        #expect(flushes[1]["check"] as? Bool == false && flushes[2]["check"] as? Bool == true)
        for method in ["hook.runNow", "hook.cancel", "prMonitor.flush", "prMonitor.cancel"] {
            #expect(connection.paramsForMethod(method).allSatisfy { $0["workspaceId"] as? String == Support.workspace })
        }
        #expect(connection.paramsForMethod("hook.cancel").first?["hookId"] as? String == "hook-1")
        #expect(connection.paramsForMethod("prMonitor.cancel").first?["monitorId"] as? String == "monitor-1")
    }
}
