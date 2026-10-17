import Foundation
@testable import Intent
import Observation
import Synchronization
import Testing

extension ScriptMonitorPresentationTests {
    @MainActor
    private struct ConversationFixture {
        let connection: FakeConnectionManager
        let cache: WorkspaceScriptMonitorsStore
        let viewModel: ConversationViewModel

        init(supported: Bool = true) {
            let connection = FakeConnectionManager()
            connection.connectionState = .connected
            connection.responseMap["events.subscribe"] = ["subscriptionId": "script-presentation-sub"]
            connection.responseMap["events.unsubscribe"] = [:] as [String: Any]
            connection.stubChatSnapshot()
            connection.responseMap["chat.unsubscribe"] = [:] as [String: Any]
            connection.responseMap["agent.get"] = ["agent": ["id": "owner", "workspaceId": "workspace", "name": "Owner"]]
            connection.responseMap["agent.getQueue"] = ["queue": []]
            connection.responseMap["agent.getSubscriptions"] = ["subscriptions": [], "delegationGroups": []]
            connection.responseMap["hook.list"] = ["hooks": []]
            connection.responseMap["prMonitor.list"] = ["monitors": []]
            connection.responseMap["scriptMonitor.list"] = ["view": "summary", "monitors": [Self.row()]]
            connection.responseMap["scriptMonitor.get"] = Self.row()
            self.connection = connection
            cache = WorkspaceScriptMonitorsStore(connection: connection) { supported }
            viewModel = ConversationViewModel(
                agentId: "owner",
                workspaceId: "workspace",
                agentName: "Owner",
                connection: connection,
                uploadService: AttachmentUploadService(connection: connection),
                optionsStore: CreationOptionsStore(connectionManager: connection),
                scriptMonitors: cache
            )
        }

        static func row(owner: String = "owner", name: String = "Build") -> [String: Any] {
            [
                "monitorId": "watch-\(owner)", "workspaceId": "workspace", "agentId": owner,
                "scriptId": "build-script", "runId": "original-watched-run", "scriptName": name,
                "mode": "command", "state": "active", "createdAt": "2026-10-17T00:00:00Z",
                "expiresAt": "2026-10-17T01:00:00Z"
            ]
        }

        func event(_ kind: String, name: String = "Build") {
            var row = Self.row(name: name)
            if kind != "registered" { row["state"] = kind }
            cache.handleEvent("events.event", params: [
                "event": ["type": "scriptMonitor:\(kind)", "workspaceId": "workspace", "data": ["monitor": row]]
            ])
        }

        func stop() {
            viewModel.teardownLiveStores()
            cache.reset()
        }
    }

    @Test func conversationLoadOwnsOneSummaryLeaseAndDoesNotFetchDetailsOrOutput() async throws {
        let fixture = ConversationFixture()
        defer { fixture.stop() }
        #expect(fixture.connection.paramsForMethod("scriptMonitor.list").isEmpty)
        #expect(!fixture.viewModel.showsScriptMonitorStatus)
        await fixture.viewModel.load()
        let lease = try #require(fixture.viewModel.scriptMonitorConsumer)
        await fixture.viewModel.load()
        #expect(fixture.viewModel.scriptMonitorConsumer == lease)
        #expect(fixture.connection.paramsForMethod("scriptMonitor.list").count == 1)
        #expect(fixture.viewModel.activeAgentScriptMonitors.map(\.runId) == ["original-watched-run"])
        #expect(fixture.connection.paramsForMethod("scriptMonitor.get").isEmpty)
        #expect(fixture.connection.requestLog.allSatisfy { !$0.method.hasPrefix("script.") })
        fixture.viewModel.teardownLiveStores()
        #expect(fixture.viewModel.scriptMonitorConsumer == nil)
        #expect(!fixture.viewModel.showsScriptMonitorStatus)
    }

    @Test func unsupportedConversationHasNoWatchStatusOrReads() async {
        let fixture = ConversationFixture(supported: false)
        defer { fixture.stop() }
        await fixture.viewModel.load()
        #expect(!fixture.viewModel.showsScriptMonitorStatus)
        #expect(fixture.viewModel.activeAgentScriptMonitors.isEmpty)
        #expect(fixture.connection.requestLog.allSatisfy { !$0.method.hasPrefix("scriptMonitor.") })
        #expect(fixture.connection.paramsForMethod("events.subscribe").allSatisfy { params in
            !(params["eventTypes"] as? [String] ?? []).contains("scriptMonitor:*")
        })
    }

    @Test func selectionRejectsOtherOwnersAndReadsOnlyTheChosenRun() async throws {
        let fixture = ConversationFixture()
        defer { fixture.stop() }
        let foreign = ConversationFixture.row(owner: "other")
        fixture.connection.responseMap["scriptMonitor.list"] = [
            "view": "summary", "monitors": [ConversationFixture.row(), foreign]
        ]
        await fixture.viewModel.load()
        fixture.viewModel.selectScriptMonitor(try ScriptMonitorSummary(foreign, workspaceId: "workspace"))
        #expect(fixture.viewModel.selectedScriptMonitor == nil)
        let owned = try #require(fixture.viewModel.activeAgentScriptMonitors.first)
        fixture.viewModel.selectScriptMonitor(owned)
        let selected = try #require(fixture.viewModel.selectedScriptMonitor)
        #expect(fixture.connection.paramsForMethod("scriptMonitor.get").isEmpty)
        await fixture.cache.loadDetail(selection: selected.id)
        await fixture.cache.loadDetail(selection: selected.id)
        #expect(fixture.connection.paramsForMethod("scriptMonitor.get").count == 1)
        #expect(fixture.connection.paramsForMethod("scriptMonitor.get").first?["monitorId"] as? String == owned.id)
        guard case let .loaded(detail) = fixture.cache.detailState(selection: selected.id) else {
            Issue.record("Selected watch detail did not load")
            return
        }
        #expect(detail.summary.runId == "original-watched-run")
        #expect(fixture.viewModel.scriptMonitorOwnerName == "Owner")
        fixture.viewModel.closeScriptMonitor()
        #expect(fixture.cache.detailState(selection: selected.id) == .unavailable)
    }

    @Test func productionProjectionObservesSameIdentityTextAndTerminalRemoval() async throws {
        let fixture = ConversationFixture()
        defer { fixture.stop() }
        await fixture.viewModel.load()
        let monitor = try #require(fixture.viewModel.activeAgentScriptMonitors.first)
        fixture.viewModel.selectScriptMonitor(monitor)
        let selection = try #require(fixture.viewModel.selectedScriptMonitor)
        await fixture.cache.loadDetail(selection: selection.id)
        let changed = Mutex(false)
        withObservationTracking { _ = fixture.viewModel.activeAgentScriptMonitors } onChange: {
            changed.withLock { $0 = true }
        }
        fixture.event("registered", name: "Renamed build")
        #expect(changed.withLock { $0 })
        #expect(fixture.viewModel.activeAgentScriptMonitors.first?.scriptName == "Renamed build")
        #expect(fixture.viewModel.activeAgentScriptMonitors.first?.id == monitor.id)
        #expect(fixture.cache.detailSummary(selection: selection.id)?.scriptName == "Renamed build")
        fixture.event("completed", name: "Renamed build")
        #expect(fixture.viewModel.activeAgentScriptMonitors.isEmpty)
        #expect(!fixture.viewModel.showsScriptMonitorStatus)
        #expect(fixture.viewModel.selectedScriptMonitor?.id == selection.id)
        #expect(fixture.cache.detailState(selection: selection.id) == .unavailable)
        #expect(fixture.cache.detailSummary(selection: selection.id) == nil)
        #expect(fixture.connection.paramsForMethod("scriptMonitor.list").count == 1)
    }

    @Test func emptyOwnerCanLoadMoreAndRetryOnlyTheFailedPage() async {
        let fixture = ConversationFixture()
        defer { fixture.stop() }
        fixture.connection.responseMap["scriptMonitor.list"] = [
            "view": "summary", "monitors": [ConversationFixture.row(owner: "other")], "nextCursor": "opaque-next"
        ]
        await fixture.viewModel.load()
        #expect(fixture.viewModel.activeAgentScriptMonitors.isEmpty)
        #expect(fixture.viewModel.showsScriptMonitorStatus)
        fixture.connection.errorMap["scriptMonitor.list"] = URLError(.timedOut)
        await fixture.cache.loadMore(workspaceId: "workspace")
        #expect(fixture.viewModel.showsScriptMonitorStatus)
        fixture.connection.errorMap = [:]
        fixture.connection.responseMap["scriptMonitor.list"] = ["view": "summary", "monitors": [ConversationFixture.row()]]
        await fixture.viewModel.retryScriptMonitors()
        #expect(fixture.viewModel.activeAgentScriptMonitors.map(\.agentId) == ["owner"])
        #expect(fixture.connection.paramsForMethod("scriptMonitor.list").last?["cursor"] as? String == "opaque-next")
        #expect(fixture.cache.nextCursor(for: "workspace") == nil)
    }

    @Test func teardownClearsSelectionAndRejectsItsLateDetail() async throws {
        let fixture = ConversationFixture()
        defer { fixture.stop() }
        await fixture.viewModel.load()
        let monitor = try #require(fixture.viewModel.activeAgentScriptMonitors.first)
        fixture.viewModel.selectScriptMonitor(monitor)
        let selection = try #require(fixture.viewModel.selectedScriptMonitor)
        fixture.connection.pendingMethods = ["scriptMonitor.get"]
        let detail = Task { await fixture.cache.loadDetail(selection: selection.id) }
        defer { detail.cancel() }
        try await fixture.connection.waitForPendingRequests("scriptMonitor.get")
        fixture.viewModel.teardownLiveStores()
        fixture.connection.resolvePending("scriptMonitor.get", with: ConversationFixture.row())
        await detail.value
        #expect(fixture.viewModel.selectedScriptMonitor == nil)
        #expect(fixture.cache.detailState(selection: selection.id) == .unavailable)
        #expect(fixture.viewModel.activeAgentScriptMonitors.isEmpty)
    }
}
