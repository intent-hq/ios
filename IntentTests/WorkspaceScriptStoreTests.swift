import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceScriptStoreTests {
    @Test func listsEveryDefinitionRegardlessOfRuntimeAndFiltersOtherWorkspaces() async {
        let fixture = WorkspaceScriptFixture()
        let statuses = ["idle", "starting", "running", "restarting", "exited", "future-state"]
        let rows = statuses.map { fixture.definition(id: $0, status: $0) }
        let missingRuntime: [String: Any] = [
            "id": "new", "workspaceId": "workspace", "name": "New command", "command": "true"
        ]
        await fixture.load(rows + [missingRuntime, rows[0], fixture.definition(workspaceId: "other"), ["id": "broken"]])
        #expect(fixture.store.scripts(workspaceId: "workspace").map(\.id) == statuses + ["new"])
        #expect(fixture.store.scripts(workspaceId: "workspace").last?.status == "idle")
        #expect(fixture.store.scriptsWithRuns(workspaceId: "workspace").map(\.id) == Array(statuses.dropFirst()))
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
    }

    @Test func idleScriptsNeedRuntimeEvidenceToAppearOnThePage() async {
        let fixture = WorkspaceScriptFixture()
        let snapshots: [[String: Any]] = [
            ["status": "idle"],
            ["status": "idle", "previouslyRunning": false],
            ["status": "idle", "startedAt": NSNull(), "stoppedAt": NSNull(), "exitCode": NSNull()],
            ["status": "idle", "previouslyRunning": true],
            ["status": "idle", "startedAt": "2026-09-28T02:00:00Z"],
            ["status": "idle", "stoppedAt": "2026-09-28T02:01:00Z"],
            ["status": "idle", "exitCode": 0]
        ]
        let definitions = snapshots.enumerated().map { index, runtime in
            var definition = fixture.definition(id: "script-\(index)")
            definition["runtime"] = runtime
            return definition
        }
        await fixture.load(definitions)
        #expect(fixture.store.scriptsWithRuns(workspaceId: "workspace").map(\.id) == ["script-3", "script-4", "script-5", "script-6"])
        #expect(fixture.store.scripts(workspaceId: "workspace").count == snapshots.count)
    }

    @Test func pageRowsFollowFirstRunCompletionAndRefresh() async throws {
        let fixture = WorkspaceScriptFixture()
        let script = try await fixture.idleScript()
        #expect(fixture.store.scriptsWithRuns(workspaceId: "workspace").isEmpty)
        fixture.startReplies()
        await fixture.store.launch(script)
        #expect(fixture.store.scriptsWithRuns(workspaceId: "workspace").map(\.status) == ["starting"])
        fixture.event(status: "exited")
        #expect(fixture.store.scriptsWithRuns(workspaceId: "workspace").map(\.status) == ["exited"])
        await fixture.load([fixture.definition(status: "exited"), fixture.definition(id: "unused")])
        #expect(fixture.store.scriptsWithRuns(workspaceId: "workspace").map(\.id) == [script.id])
        #expect(fixture.store.scriptsWithRuns(workspaceId: "other").isEmpty)
    }

    @Test func launchesWithStartAndOpensDetectedURLExactlyOnce() async throws {
        let fixture = WorkspaceScriptFixture()
        let script = try await fixture.idleScript()
        fixture.startReplies()
        await fixture.store.launch(script)
        #expect(fixture.store.isLaunching(script))
        let methods = fixture.fake.requestLog.map(\.method)
        #expect(methods == ["events.subscribe", "script.list", "script.status", "script.start", "script.status"])
        let params = try #require(fixture.fake.paramsForMethod("script.start").first)
        #expect(params["workspaceId"] as? String == "workspace")
        #expect(params["scriptId"] as? String == "preview")
        fixture.event(url: "http://daemon.localhost:5173/preview")
        #expect(!fixture.store.isLaunching(script))
        let browser = try #require(fixture.store.takeBrowserToOpen(workspaceId: "workspace"))
        #expect(browser.url == "http://127.0.0.1:5173/preview")
        #expect(browser.command == "npm run dev")
        #expect(fixture.store.takeBrowserToOpen(workspaceId: "workspace") == nil)
        fixture.event(url: "http://localhost:5173/preview")
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
        #expect(!fixture.fake.didCallMethod("script.run"))
    }

    @Test func alreadyActiveScriptsReuseStatusWithoutRestarting() async throws {
        let statuses = ["starting", "running", "restarting", "future-state"]
        for status in statuses {
            let fixture = WorkspaceScriptFixture()
            let script = try await fixture.idleScript()
            fixture.fake.responseMap["script.status"] = fixture.runtime(status: status, url: "localhost:3000")
            await fixture.store.launch(script)
            #expect(!fixture.fake.didCallMethod("script.start"))
            if status == "running" {
                #expect(fixture.store.takeBrowserToOpen(workspaceId: "workspace")?.url == "http://127.0.0.1:3000")
            } else {
                #expect(fixture.store.isLaunching(script) == ["starting", "restarting"].contains(status))
                #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
                fixture.event(url: "localhost:4000")
                #expect(fixture.store.takeBrowserToOpen(workspaceId: "workspace")?.url == "http://127.0.0.1:4000")
            }
        }
    }

    @Test func unrelatedRunningScriptsNeverPresentABrowser() async {
        let fixture = WorkspaceScriptFixture()
        await fixture.load([fixture.definition(status: "running", url: "localhost:3000")])
        fixture.event(url: "localhost:4000")
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
        #expect(fixture.store.scripts(workspaceId: "workspace").first?.detectedURL == "localhost:4000")
        #expect(!fixture.fake.didCallMethod("script.start"))
    }

    @Test func commandCompletionEndsLaunchAndDoesNotUsePreviousURL() async throws {
        let fixture = WorkspaceScriptFixture()
        let script = try await fixture.idleScript()
        fixture.startReplies(status: "exited", url: "localhost:3000")
        await fixture.store.launch(script)
        #expect(!fixture.store.isLaunching(script))
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
        #expect(fixture.store.errorMessage(workspaceId: "workspace") == nil)
        fixture.event(url: "localhost:4000")
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
    }

    @Test func invalidDetectedURLWaitsForUsableURLAndClearedFieldsDisappear() async throws {
        let fixture = WorkspaceScriptFixture()
        let script = try await fixture.idleScript()
        fixture.startReplies(status: "running", url: "file:///secret")
        await fixture.store.launch(script)
        #expect(!fixture.store.isLaunching(script))
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
        fixture.event(status: "restarting")
        #expect(fixture.store.scripts(workspaceId: "workspace").first?.detectedURL == nil)
        fixture.event(url: "https://example.com/preview")
        #expect(fixture.store.takeBrowserToOpen(workspaceId: "workspace")?.url == "https://example.com/preview")
    }

    @Test func runningWithoutURLStopsStartupIndicatorButKeepsOnePendingPresentation() async throws {
        let fixture = WorkspaceScriptFixture()
        let script = try await fixture.idleScript()
        fixture.startReplies(status: "running")
        await fixture.store.launch(script)
        #expect(!fixture.store.isLaunching(script))
        #expect(fixture.store.scripts(workspaceId: "workspace").first?.status == "running")
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
        let requestCount = fixture.fake.requestLog.count
        await fixture.store.launch(script)
        #expect(fixture.fake.requestLog.count == requestCount)
        fixture.event(url: "localhost:3000")
        #expect(fixture.store.takeBrowserToOpen(workspaceId: "workspace")?.url == "http://127.0.0.1:3000")
        #expect(fixture.store.takeBrowserToOpen(workspaceId: "workspace") == nil)
        fixture.event(url: "localhost:3000")
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
    }

    @Test func failedStartShowsErrorUntilANewLaunch() async throws {
        let fixture = WorkspaceScriptFixture()
        let script = try await fixture.idleScript()
        fixture.startReplies()
        fixture.fake.errorMap["script.start"] = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Launch refused"])
        await fixture.store.launch(script)
        #expect(fixture.store.errorMessage(workspaceId: "workspace") == "Launch refused")
        #expect(!fixture.store.isLaunching(script))
        #expect(fixture.store.scriptsWithRuns(workspaceId: "workspace").isEmpty)
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.errorMessage(workspaceId: "workspace") == "Launch refused")
        fixture.fake.errorMap.removeAll()
        fixture.startReplies(status: "running", url: "localhost:3000")
        await fixture.store.launch(script)
        #expect(fixture.store.errorMessage(workspaceId: "workspace") == nil)
        #expect(fixture.store.takeBrowserToOpen(workspaceId: "workspace") != nil)
    }

    @Test func terminalEventShowsSpawnErrorAndStopsWaitingSynchronously() async throws {
        let fixture = WorkspaceScriptFixture()
        let script = try await fixture.idleScript()
        fixture.startReplies()
        await fixture.store.launch(script)
        fixture.event(status: "exited", error: "Working directory is missing")
        #expect(fixture.store.errorMessage(workspaceId: "workspace") == "Working directory is missing")
        #expect(fixture.store.scripts(workspaceId: "workspace").first?.error == "Working directory is missing")
        #expect(!fixture.store.isLaunching(script))
        fixture.event(url: "localhost:3000")
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
    }

    @Test func aSuccessfulRefreshClearsItsPreviousDiscoveryError() async {
        let fixture = WorkspaceScriptFixture()
        fixture.fake.responseMap["script.list"] = ["unexpected": []]
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.errorMessage(workspaceId: "workspace") != nil)
        await fixture.load([fixture.definition()])
        #expect(fixture.store.errorMessage(workspaceId: "workspace") == nil)
    }

    @Test func definitionChangeRefreshesTheListWithoutLaunching() async {
        let fixture = WorkspaceScriptFixture()
        await fixture.load([fixture.definition()])
        fixture.fake.responseMap["script.list"] = ["scripts": [fixture.definition(), fixture.definition(id: "checks")]]
        fixture.changed(id: "checks", action: "created")
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.scripts(workspaceId: "workspace").map(\.id) == ["preview", "checks"])
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
        #expect(!fixture.fake.didCallMethod("script.start"))
    }

    @Test func clearingRuntimeURLClearsAnUnconsumedBrowser() async throws {
        let fixture = WorkspaceScriptFixture()
        let script = try await fixture.idleScript()
        fixture.fake.responseMap["script.status"] = fixture.runtime(status: "running", url: "localhost:3000")
        await fixture.store.launch(script)
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") != nil)
        fixture.event()
        #expect(fixture.store.takeBrowserToOpen(workspaceId: "workspace") == nil)
        #expect(fixture.store.scripts(workspaceId: "workspace").first?.detectedURL == nil)
    }

    @Test func demoScriptsStartIdleAndProduceDeterministicRuntime() throws {
        let workspaceId = UUID().uuidString
        let params = ["workspaceId": workspaceId]
        let before = DemoBrowserFixtures.scriptResponse(for: "script.list", params: params) as? [String: Any]
        let rows = try #require(before?["scripts"] as? [[String: Any]])
        #expect(rows.compactMap { WorkspaceScript(definition: $0, workspaceId: workspaceId) }.map(\.status) == ["idle", "idle"])
        for id in ["demo-server", "demo-check"] {
            let input = ["workspaceId": workspaceId, "scriptId": id]
            _ = DemoBrowserFixtures.scriptResponse(for: "script.start", params: input)
            let runtime = try #require(DemoBrowserFixtures.scriptResponse(for: "script.status", params: input) as? [String: Any])
            #expect(runtime["status"] as? String == (id == "demo-server" ? "running" : "exited"))
            #expect((runtime["detectedUrl"] is String) == (id == "demo-server"))
        }
        let after = DemoBrowserFixtures.scriptResponse(for: "script.list", params: params) as? [String: Any]
        let updated = try #require(after?["scripts"] as? [[String: Any]])
        #expect(updated.compactMap { WorkspaceScript(definition: $0, workspaceId: workspaceId) }.map(\.status) == ["running", "exited"])
        let other = DemoBrowserFixtures.scriptResponse(for: "script.status", params: ["workspaceId": UUID().uuidString, "scriptId": "demo-server"]) as? [String: Any]
        #expect(other?["status"] as? String == "idle")
    }
}
