#if DEBUG
import Foundation
@testable import Intent
import Testing

@MainActor
struct DemoScriptMonitorFixturesTests {
    @Test func fixturesRequireExplicitScenarioAndDemoOptIn() {
        #expect(DemoScriptMonitorFixtures.configured(arguments: ["--demo-script-monitors=active"]) == nil)
        #expect(DemoScriptMonitorFixtures.configured(arguments: ["--demo-data"]) == nil)
        #expect(DemoScriptMonitorFixtures.configured(arguments: ["--demo-data", "--demo-script-monitors=unknown"]) == nil)
        #expect(DemoScriptMonitorFixtures.configured(arguments: ["--demo-data", "--demo-script-monitors=active"])?.supportsMonitors == true)
        #expect(DemoScriptMonitorFixtures.configured(arguments: ["--demo-data", "--demo-script-monitors=unsupported"])?.supportsMonitors == false)
        #expect(DemoScriptMonitorFixtures.configuredPresentationDate(arguments: []) == nil)
        let arguments = ["--demo-data", "--demo-script-monitors=active"]
        #expect(DemoScriptMonitorFixtures.configured(arguments: arguments)?.anchor == DemoScriptMonitorFixtures.configuredPresentationDate(arguments: arguments))
    }

    @Test func summaryHasTwoOwnersAndFullPatternIsOnlyInDetail() async throws {
        let fixture = DemoScriptMonitorFixtures(scenario: .active)
        let response = try #require(try await fixture.response(for: "scriptMonitor.list", params: listParams) as? [String: Any])
        let rows = try #require(response["monitors"] as? [[String: Any]])
        #expect(response["view"] as? String == "summary")
        #expect(Set(rows.compactMap { $0["agentId"] as? String }).count == 2)
        #expect(rows.allSatisfy { $0["state"] as? String == "active" && $0["outputPattern"] == nil })
        let page = try ScriptMonitorPage(response, workspaceId: DemoDesignFixtures.workspaceId)
        #expect(page.monitors.count == 2)
        let owned = try #require(page.monitors.first { $0.id == DemoScriptMonitorFixtures.monitorId })
        #expect(owned.outputPatternTruncated == true)
        #expect((owned.outputPatternPreview?.utf8.count ?? 0) <= ScriptMonitorSummary.previewByteLimit)
        #expect(DemoScriptMonitorFixtures.fullPattern.utf8.count > ScriptMonitorSummary.previewByteLimit)
        let detail = try #require(try await fixture.response(for: "scriptMonitor.get", params: detailParams) as? [String: Any])
        #expect(detail["outputPattern"] as? String == DemoScriptMonitorFixtures.fullPattern)
        #expect(detail["runId"] as? String == DemoScriptMonitorFixtures.runId)
        let parsed = try ScriptMonitorDetail(detail, workspaceId: DemoDesignFixtures.workspaceId, monitorId: DemoScriptMonitorFixtures.monitorId)
        #expect(parsed.outputPattern == DemoScriptMonitorFixtures.fullPattern)
        #expect(fixture.requests == ["scriptMonitor.list", "scriptMonitor.get"])
    }

    @Test func textUpdateAndTerminalEventsKeepIdentityAndChangeSubsequentReads() async throws {
        let fixture = DemoScriptMonitorFixtures(scenario: .active)
        let update = try #require(fixture.consume(.rename))
        #expect(update["type"] as? String == "scriptMonitor:registered")
        let data = try #require(update["data"] as? [String: Any])
        let row = try #require(data["monitor"] as? [String: Any])
        #expect(row["monitorId"] as? String == DemoScriptMonitorFixtures.monitorId)
        #expect(row["scriptName"] as? String == DemoScriptMonitorFixtures.updatedName)
        #expect(fixture.consume(.rename) == nil)
        let terminal = try #require(fixture.consume(.completed))
        #expect(terminal["type"] as? String == "scriptMonitor:completed")
        let response = try #require(try await fixture.response(for: "scriptMonitor.list", params: listParams) as? [String: Any])
        let rows = try #require(response["monitors"] as? [[String: Any]])
        #expect(!rows.contains { $0["monitorId"] as? String == DemoScriptMonitorFixtures.monitorId })
        await #expect(throws: NSError.self) { _ = try await fixture.response(for: "scriptMonitor.get", params: detailParams) }
    }

    @Test func emptyOwnerPageKeepsCursorAndRetryIsScopedToNextPage() async throws {
        let fixture = DemoScriptMonitorFixtures(scenario: .pageRetry)
        let first = try #require(try await fixture.response(for: "scriptMonitor.list", params: listParams) as? [String: Any])
        let rows = try #require(first["monitors"] as? [[String: Any]])
        #expect(rows.allSatisfy { $0["agentId"] as? String != DemoDesignFixtures.agentId })
        let cursor = try #require(first["nextCursor"] as? String)
        var params = listParams
        params["cursor"] = cursor
        await #expect(throws: NSError.self) { _ = try await fixture.response(for: "scriptMonitor.list", params: params) }
        let next = try #require(try await fixture.response(for: "scriptMonitor.list", params: params) as? [String: Any])
        #expect(next["nextCursor"] == nil)
        #expect((next["monitors"] as? [[String: Any]])?.first?["agentId"] as? String == DemoDesignFixtures.agentId)
    }

    @Test func fixtureRejectsCrossWorkspaceAndUnboundedReadShapes() async {
        let fixture = DemoScriptMonitorFixtures(scenario: .active)
        await #expect(throws: NSError.self) { _ = try await fixture.response(for: "scriptMonitor.list", params: [:]) }
        var foreign = listParams
        foreign["workspaceId"] = "foreign-workspace"
        await #expect(throws: NSError.self) { _ = try await fixture.response(for: "scriptMonitor.list", params: foreign) }
    }

    @Test func fileEventsReachRealConnectionHandlersAndSharedStoreWithoutReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = ConnectionManager()
        manager.connectDemo(serveFixtures: true)
        manager.configureDemoScriptMonitors(serveFixtures: true, arguments: [
            "--demo-data", "--demo-script-monitors=active", "--demo-script-monitor-directory=" + directory.path
        ])
        defer { manager.disconnect() }
        let store = WorkspaceScriptMonitorsStore(connection: manager)
        let workspace = DemoDesignFixtures.workspaceId
        let consumer = store.retain(workspaceId: workspace)
        defer { store.release(workspaceId: workspace, consumer: consumer) }
        await store.load(workspaceId: workspace)
        #expect(store.rows(for: workspace).count == 2)
        try Data().write(to: directory.appendingPathComponent("rename"))
        try await waitUntil("file-triggered rename reaches shared store") {
            store.rows(for: workspace).contains { $0.scriptName == DemoScriptMonitorFixtures.updatedName }
        }
        try Data().write(to: directory.appendingPathComponent("completed"))
        try await waitUntil("file-triggered completion removes owned watch") {
            !store.rows(for: workspace).contains { $0.id == DemoScriptMonitorFixtures.monitorId }
        }
        let fixture = try #require(manager.demoScriptMonitorFixtures)
        #expect(fixture.requests.filter { $0 == "scriptMonitor.list" }.count == 1)
        #expect(fixture.requests.filter { $0 == "events.subscribe:scriptMonitor" }.count == 1)
        #expect(!fixture.requests.contains("scriptMonitor.get"))
    }

    private var listParams: [String: Any] {
        ["workspaceId": DemoDesignFixtures.workspaceId, "view": "summary", "state": "active", "limit": 100]
    }

    private var detailParams: [String: Any] {
        ["workspaceId": DemoDesignFixtures.workspaceId, "monitorId": DemoScriptMonitorFixtures.monitorId]
    }
}
#endif
