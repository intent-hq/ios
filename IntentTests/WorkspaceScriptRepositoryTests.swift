import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceScriptRepositoryTests {
    @Test func discoversManifestScriptsAlongsideSavedCommandsWithoutRegistering() async {
        let fixture = await catalogFixture()
        let scripts = fixture.store.scripts(workspaceId: "workspace")
        #expect(Set(scripts.map(\.name)) == ["Web preview", "dev", "build"])
        #expect(scripts.filter { !$0.isRegistered }.count == 2)
        #expect(fixture.store.scriptsWithRuns(workspaceId: "workspace").isEmpty)
        #expect(!fixture.fake.didCallMethod("script.create"))
        #expect(!fixture.fake.didCallMethod("script.start"))
        #expect(fixture.fake.paramsForMethod("file.read").compactMap { $0["path"] as? String } == ["package.json"])
        #expect(fixture.fake.paramsForMethod("file.list").first?["workspaceId"] as? String == "workspace")
    }

    @Test func registeredNameAndCommandTakePrecedenceOverManifestCandidates() async throws {
        let fixture = await catalogFixture()
        let candidates = fixture.store.scripts(workspaceId: "workspace").filter { !$0.isRegistered }
        let dev = try #require(candidates.first { $0.name == "dev" })
        let build = try #require(candidates.first { $0.name == "build" })
        var named = registered(dev)
        named["command"] = "custom development command"
        var renamed = registered(build)
        renamed["name"] = "Build website"
        await fixture.load([named, renamed])
        #expect(fixture.store.scripts(workspaceId: "workspace").allSatisfy(\.isRegistered))
        #expect(fixture.store.scripts(workspaceId: "workspace").count == 2)
        #expect(!fixture.fake.didCallMethod("script.create"))
    }

    @Test func firstLaunchRegistersOnceThenStartsAndOpensTheDetectedServer() async throws {
        let fixture = await catalogFixture()
        let candidate = try #require(fixture.store.scripts(workspaceId: "workspace").first { $0.name == "dev" })
        fixture.fake.responseMap["script.create"] = registered(candidate)
        fixture.startReplies(status: "running", url: "localhost:4321")
        await fixture.store.launch(candidate)
        let create = try #require(fixture.fake.paramsForMethod("script.create").first)
        #expect(create["name"] as? String == "dev")
        #expect(create["command"] as? String == candidate.command)
        #expect(create["mode"] as? String == "service")
        #expect(create["scriptId"] == nil)
        #expect(fixture.fake.paramsForMethod("script.start").first?["scriptId"] as? String == "registered-dev")
        #expect(fixture.store.takeBrowserToOpen(workspaceId: "workspace")?.url == "http://127.0.0.1:4321")
        #expect(fixture.store.scriptsWithRuns(workspaceId: "workspace").map(\.id) == ["registered-dev"])
        #expect(fixture.store.scripts(workspaceId: "workspace").filter { $0.name == "dev" }.count == 1)
        let running = try #require(fixture.store.scriptsWithRuns(workspaceId: "workspace").first)
        await fixture.store.launch(running)
        #expect(fixture.fake.paramsForMethod("script.create").count == 1)
        #expect(fixture.fake.paramsForMethod("script.start").count == 1)
    }

    @Test func rechecksDaemonBeforeCreatingAndReusesARecentlyRegisteredScript() async throws {
        let fixture = await catalogFixture()
        let candidate = try #require(fixture.store.scripts(workspaceId: "workspace").first { $0.name == "dev" })
        fixture.fake.responseMap["script.list"] = ["scripts": [registered(candidate)]]
        fixture.fake.responseMap["script.status"] = fixture.runtime(status: "running", url: "localhost:4321")
        await fixture.store.launch(candidate)
        #expect(!fixture.fake.didCallMethod("script.create"))
        #expect(!fixture.fake.didCallMethod("script.start"))
        #expect(fixture.store.takeBrowserToOpen(workspaceId: "workspace")?.id == "script:registered-dev")
    }

    @Test func registrationEventDoesNotCancelTheLaunchBeforeCreateReplies() async throws {
        let fixture = await catalogFixture()
        let candidate = try #require(fixture.store.scripts(workspaceId: "workspace").first { $0.name == "dev" })
        fixture.fake.pendingMethods.insert("script.create")
        let launch = Task { await fixture.store.launch(candidate) }
        try await fixture.fake.waitForPendingRequests("script.create")
        fixture.fake.responseMap["script.list"] = ["scripts": [registered(candidate)]]
        fixture.changed(id: "registered-dev", action: "created")
        await fixture.store.refresh(workspaceId: "workspace")
        fixture.fake.responseMap["script.status"] = fixture.runtime(status: "running", url: "localhost:4321")
        fixture.fake.resolvePending("script.create", with: registered(candidate))
        await launch.value
        #expect(fixture.store.takeBrowserToOpen(workspaceId: "workspace")?.url == "http://127.0.0.1:4321")
    }

    @Test func simultaneousWindowsShareRegistration() async throws {
        let fixture = await catalogFixture()
        let second = WorkspaceScriptStore(connection: fixture.fake)
        await second.refresh(workspaceId: "workspace")
        let candidate = try #require(fixture.store.scripts(workspaceId: "workspace").first { $0.name == "dev" })
        fixture.fake.pendingMethods.insert("script.create")
        let firstLaunch = Task { await fixture.store.launch(candidate) }
        try await fixture.fake.waitForPendingRequests("script.create")
        let secondLaunch = Task { await second.launch(candidate) }
        try await waitUntil("second window launching") { second.isLaunching(candidate) }
        fixture.fake.responseMap["script.list"] = ["scripts": [registered(candidate)]]
        fixture.fake.responseMap["script.status"] = fixture.runtime(status: "running", url: "localhost:4321")
        fixture.fake.resolvePending("script.create", with: registered(candidate))
        await firstLaunch.value
        await secondLaunch.value
        #expect(fixture.fake.paramsForMethod("script.create").count == 1)
        #expect(fixture.store.takeBrowserToOpen(workspaceId: "workspace") != nil)
        #expect(second.takeBrowserToOpen(workspaceId: "workspace") != nil)
    }

    @Test func leavingDuringRegistrationPreventsServerLaunch() async throws {
        let fixture = await catalogFixture()
        let candidate = try #require(fixture.store.scripts(workspaceId: "workspace").first { $0.name == "dev" })
        fixture.fake.pendingMethods.insert("script.create")
        let launch = Task { await fixture.store.launch(candidate) }
        try await fixture.fake.waitForPendingRequests("script.create")
        fixture.store.cancelPendingLaunch(workspaceId: "workspace")
        fixture.fake.resolvePending("script.create", with: registered(candidate))
        await launch.value
        #expect(!fixture.fake.didCallMethod("script.start"))
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
    }

    @Test func failedRegistrationRemainsMenuOnlyAndDoesNotStart() async throws {
        let fixture = await catalogFixture()
        let candidate = try #require(fixture.store.scripts(workspaceId: "workspace").first { $0.name == "dev" })
        fixture.fake.errorMap["script.create"] = NSError(domain: "test", code: 1)
        await fixture.store.launch(candidate)
        #expect(fixture.store.errorMessage(workspaceId: "workspace") != nil)
        #expect(fixture.store.scriptsWithRuns(workspaceId: "workspace").isEmpty)
        #expect(!fixture.fake.didCallMethod("script.start"))
        #expect(fixture.store.scripts(workspaceId: "workspace").contains { $0.id == candidate.id })
    }

    @Test func removedManifestClearsCandidatesButKeepsSavedScripts() async {
        let fixture = await catalogFixture()
        fixture.fake.responseMap["file.list"] = [[String: Any]]()
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.scripts(workspaceId: "workspace").map(\.id) == ["verification"])
    }

    private func catalogFixture() async -> WorkspaceScriptFixture {
        let fixture = WorkspaceScriptFixture()
        fixture.fake.responseMap["file.list"] = [
            ["name": "package.json", "type": "file"], ["name": "pnpm-lock.yaml", "type": "file"]
        ]
        fixture.fake.responseMap["file.read"] = #"{"packageManager":"pnpm@10.30.3","scripts":{"dev":"astro dev","build":"astro build"}}"#
        await fixture.load([fixture.definition(id: "verification")])
        return fixture
    }

    private func registered(_ candidate: WorkspaceScript) -> [String: Any] {
        [
            "id": "registered-\(candidate.name)", "workspaceId": candidate.workspaceId,
            "name": candidate.name, "command": candidate.command, "mode": candidate.mode
        ]
    }
}
