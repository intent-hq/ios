import Foundation
@testable import Intent
import Testing

@MainActor
struct MobileTerminalStoreTests {
    @Test func shortcutCreatesWhenNoMobileTerminalExists() async throws {
        let fixture = try MobileTerminalFixture()
        fixture.list(ids: ["desktop"])
        let terminal = try #require(await fixture.store.openOrCreate(workspaceId: "workspace"))
        #expect(terminal.workspaceId == "workspace")
        #expect(fixture.fake.paramsForMethod("terminal.create").count == 1)
    }

    @Test func shortcutReusesAnExistingTerminalButExplicitCreateStillCreates() async throws {
        let fixture = try MobileTerminalFixture()
        let terminal = try await fixture.create()
        fixture.fake.clearRequestLog()
        #expect(await fixture.store.openOrCreate(workspaceId: "workspace") == terminal)
        #expect(!fixture.fake.didCallMethod("terminal.create"))
        fixture.fake.responseMap["terminal.create"] = ["terminalId": "second-mobile"]
        #expect(await fixture.store.create(workspaceId: "workspace")?.id == "second-mobile")
        #expect(fixture.fake.paramsForMethod("terminal.create").count == 1)
    }

    @Test func shortcutReplacesAnEndedTerminal() async throws {
        let fixture = try MobileTerminalFixture()
        _ = try await fixture.create()
        fixture.list(ids: [])
        fixture.fake.responseMap["terminal.create"] = ["terminalId": "replacement"]
        #expect(await fixture.store.openOrCreate(workspaceId: "workspace")?.id == "replacement")
        #expect(fixture.store.activeTerminals(workspaceId: "workspace").map(\.id) == ["replacement"])
    }

    @Test func shortcutDoesNotCreateAfterFailedReconciliation() async throws {
        let fixture = try MobileTerminalFixture()
        _ = try await fixture.create()
        fixture.fake.clearRequestLog()
        fixture.fake.errorMap["terminal.list"] = MobileTerminalError.disconnected
        #expect(await fixture.store.openOrCreate(workspaceId: "workspace") == nil)
        #expect(!fixture.fake.didCallMethod("terminal.create"))
    }

    @Test func shortcutCanRetryAFailedInitialCreation() async throws {
        let fixture = try MobileTerminalFixture()
        fixture.fake.errorMap["terminal.create"] = MobileTerminalError.disconnected
        #expect(await fixture.store.openOrCreate(workspaceId: "workspace") == nil)
        fixture.fake.errorMap["terminal.create"] = nil
        #expect(await fixture.store.openOrCreate(workspaceId: "workspace") != nil)
    }

    @Test func visitingAndRefreshingNeverCreatesOrAdoptsDesktopTerminals() async throws {
        let fixture = try MobileTerminalFixture()
        fixture.list(ids: ["desktop", "setup"])
        await fixture.store.refresh(workspaceId: "workspace")
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.activeTerminals(workspaceId: "workspace").isEmpty)
        #expect(!fixture.fake.didCallMethod("terminal.create"))
    }

    @Test func explicitCreationIsWorkspaceScopedAndPersisted() async throws {
        let fixture = try MobileTerminalFixture()
        let terminal = try await fixture.create()
        #expect(fixture.store.activeTerminals(workspaceId: "workspace") == [terminal])
        #expect(fixture.store.activeTerminals(workspaceId: "other").isEmpty)
        #expect(fixture.persistence.load() == [terminal])
        let params = try #require(fixture.fake.paramsForMethod("terminal.create").first)
        #expect(params["workspaceId"] as? String == "workspace")
        #expect(params["command"] == nil)
    }

    @Test func concurrentCreateRequestsDoNotDuplicateShells() async throws {
        let fixture = try MobileTerminalFixture()
        fixture.fake.pendingMethods.insert("terminal.create")
        let creation = Task { await fixture.store.create(workspaceId: "workspace") }
        try await fixture.fake.waitForPendingRequests("terminal.create")
        #expect(await fixture.store.create(workspaceId: "workspace") == nil)
        fixture.fake.resolvePending("terminal.create", with: ["terminalId": "mobile"])
        #expect(await creation.value != nil)
        #expect(fixture.fake.paramsForMethod("terminal.create").count == 1)
    }

    @Test func relaunchRestoresOnlyRecordedSessionsFromTheSameDaemonBoot() async throws {
        let fixture = try MobileTerminalFixture()
        let terminal = try await fixture.create()
        let restored = MobileTerminalStore(connection: fixture.fake, persistence: fixture.persistence)
        fixture.fake.clearRequestLog()
        fixture.list(ids: [terminal.id, "desktop"])
        await restored.refresh(workspaceId: "workspace")
        #expect(restored.activeTerminals(workspaceId: "workspace") == [terminal])
        #expect(!fixture.fake.didCallMethod("terminal.create"))
    }

    @Test func daemonRestartDoesNotAdoptAReusedTerminalId() async throws {
        let fixture = try MobileTerminalFixture()
        let terminal = try await fixture.create()
        fixture.list(ids: [terminal.id], bootId: "new-boot")
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.activeTerminals(workspaceId: "workspace").isEmpty)
        #expect(fixture.persistence.load().isEmpty)
        #expect(await fixture.store.close(terminal))
        #expect(!fixture.fake.didCallMethod("terminal.kill"))
    }

    @Test func aFailedRefreshPreservesSessionsAndNeverCreatesReplacements() async throws {
        let fixture = try MobileTerminalFixture()
        let terminal = try await fixture.create()
        fixture.fake.clearRequestLog()
        fixture.fake.errorMap["terminal.list"] = MobileTerminalError.disconnected
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.activeTerminals(workspaceId: "workspace") == [terminal])
        #expect(fixture.store.errorMessage(workspaceId: "workspace") != nil)
        #expect(!fixture.fake.didCallMethod("terminal.create"))
    }

    @Test func errorsAreScopedToTheirWorkspace() async throws {
        let fixture = try MobileTerminalFixture()
        _ = try await fixture.create()
        fixture.fake.errorMap["terminal.list"] = MobileTerminalError.disconnected
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.errorMessage(workspaceId: "workspace") != nil)
        #expect(fixture.store.errorMessage(workspaceId: "other") == nil)
        fixture.store.clearError(workspaceId: "workspace")
        #expect(fixture.store.errorMessage(workspaceId: "workspace") == nil)
    }

    @Test func aShellCreatedAcrossAReconnectIsKeptRatherThanOrphaned() async throws {
        let fixture = try MobileTerminalFixture()
        fixture.fake.pendingMethods.insert("terminal.create")
        let creation = Task { await fixture.store.create(workspaceId: "workspace") }
        try await fixture.fake.waitForPendingRequests("terminal.create")
        fixture.fake.connectionState = .disconnected
        fixture.fake.connectionState = .connected
        fixture.list(ids: ["mobile"])
        fixture.fake.resolvePending("terminal.create", with: ["terminalId": "mobile"])
        let terminal = try #require(await creation.value)
        #expect(terminal.id == "mobile")
        #expect(fixture.store.activeTerminals(workspaceId: "workspace") == [terminal])
        #expect(fixture.persistence.load() == [terminal])
        #expect(fixture.store.errorMessage(workspaceId: "workspace") == nil)
    }

    @Test func exitingRemovesTheMobileRowAndItsSavedIdentity() async throws {
        let fixture = try MobileTerminalFixture()
        let terminal = try await fixture.create()
        fixture.event(type: "terminal:exit", id: terminal.id)
        #expect(fixture.store.activeTerminals(workspaceId: "workspace").isEmpty)
        #expect(fixture.persistence.load().isEmpty)
    }

    @Test func explicitCloseKillsOnlyTheSelectedMobileSession() async throws {
        let fixture = try MobileTerminalFixture()
        let terminal = try await fixture.create()
        #expect(await fixture.store.close(terminal))
        let params = try #require(fixture.fake.paramsForMethod("terminal.kill").first)
        #expect(params["terminalId"] as? String == terminal.id)
        #expect(fixture.persistence.load().isEmpty)
    }

    @Test func aFailedCloseKeepsTheSessionAvailable() async throws {
        let fixture = try MobileTerminalFixture()
        let terminal = try await fixture.create()
        fixture.fake.errorMap["terminal.kill"] = MobileTerminalError.disconnected
        #expect(!(await fixture.store.close(terminal)))
        #expect(fixture.store.activeTerminals(workspaceId: "workspace") == [terminal])
    }

    @Test func reconnectRefreshesWithoutCreatingAShell() async throws {
        let fixture = try MobileTerminalFixture()
        let terminal = try await fixture.create()
        fixture.fake.clearRequestLog()
        fixture.fake.connectionState = .disconnected
        fixture.fake.connectionState = .connected
        try await fixture.fake.waitForRequests("terminal.list")
        #expect(fixture.store.activeTerminals(workspaceId: "workspace") == [terminal])
        #expect(!fixture.fake.didCallMethod("terminal.create"))
    }

    @Test func aStaleRefreshCannotRemoveANewlyCreatedTerminal() async throws {
        let fixture = try MobileTerminalFixture()
        _ = try await fixture.create()
        fixture.fake.pendingMethods.insert("terminal.list")
        let refresh = Task { await fixture.store.refresh(workspaceId: "workspace") }
        try await fixture.fake.waitForPendingRequests("terminal.list")
        fixture.fake.pendingMethods.remove("terminal.list")
        fixture.fake.responseMap["terminal.create"] = ["terminalId": "second-mobile"]
        let terminal = try await fixture.create()
        fixture.fake.resolvePending("terminal.list", with: ["daemonBootId": "boot", "terminals": []])
        await refresh.value
        #expect(fixture.store.activeTerminals(workspaceId: "workspace").contains(terminal))
    }

    @Test func titleFollowsTheRunningThenLastProgramThenTheTerminalName() async throws {
        let fixture = try MobileTerminalFixture()
        let terminal = try await fixture.create()
        #expect(fixture.store.title(for: terminal) == "Terminal 1")

        fixture.list(ids: [terminal.id], fields: ["foregroundProcess": "claude", "lastProcess": "npm"])
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.title(for: terminal) == "claude")
        #expect(!fixture.store.hasExitedProcess(terminal))

        fixture.list(ids: [terminal.id], fields: ["foregroundProcess": NSNull(), "lastProcess": "claude"])
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.title(for: terminal) == "claude")
        #expect(fixture.store.hasExitedProcess(terminal))
    }

    @Test func processEventsRenameTheTerminalAndSubscribeAlongsideExit() async throws {
        let fixture = try MobileTerminalFixture()
        let terminal = try await fixture.create()
        let subscribe = try #require(fixture.fake.paramsForMethod("events.subscribe").first)
        #expect(subscribe["eventTypes"] as? [String] == ["terminal:exit", "terminal:process"])

        fixture.processEvent(id: terminal.id, foreground: "vim", last: nil)
        #expect(fixture.store.title(for: terminal) == "vim")
        fixture.processEvent(id: terminal.id, foreground: nil, last: "vim")
        #expect(fixture.store.title(for: terminal) == "vim")
        #expect(fixture.store.hasExitedProcess(terminal))
        fixture.processEvent(id: terminal.id, foreground: "top", last: nil, workspaceId: "other")
        #expect(fixture.store.title(for: terminal) == "vim")
    }

    @Test func aListStartedBeforeAProcessEventDoesNotOverwriteIt() async throws {
        let fixture = try MobileTerminalFixture()
        let terminal = try await fixture.create()
        fixture.fake.pendingMethods.insert("terminal.list")
        let refresh = Task { await fixture.store.refresh(workspaceId: "workspace") }
        try await fixture.fake.waitForPendingRequests("terminal.list")
        fixture.processEvent(id: terminal.id, foreground: "make", last: nil)
        fixture.fake.resolvePending("terminal.list", with: [
            "daemonBootId": "boot",
            "terminals": [["id": terminal.id, "name": "Terminal", "foregroundProcess": NSNull(), "lastProcess": NSNull()]]
        ])
        await refresh.value
        #expect(fixture.store.title(for: terminal) == "make")
    }

    @Test func aProcessEventSkipsOnlyItsOwnRowInAPendingList() async throws {
        let fixture = try MobileTerminalFixture()
        let first = try await fixture.create()
        fixture.fake.responseMap["terminal.create"] = ["terminalId": "second"]
        let second = try await fixture.create()
        fixture.fake.responseMap["terminal.create"] = ["terminalId": "elsewhere"]
        let elsewhere = try #require(await fixture.store.create(workspaceId: "other"))
        fixture.list(ids: [first.id, second.id])

        fixture.fake.pendingMethods.insert("terminal.list")
        let refresh = Task { await fixture.store.refresh(workspaceId: "workspace") }
        try await fixture.fake.waitForPendingRequests("terminal.list")
        fixture.processEvent(id: first.id, foreground: "make", last: nil)
        fixture.processEvent(id: elsewhere.id, foreground: "top", last: nil, workspaceId: "other")
        fixture.fake.resolvePending("terminal.list", with: [
            "daemonBootId": "boot",
            "terminals": [
                ["id": first.id, "name": "Terminal", "foregroundProcess": NSNull(), "lastProcess": NSNull()],
                ["id": second.id, "name": "Terminal", "foregroundProcess": "sleep", "lastProcess": "vim"]
            ]
        ])
        await refresh.value
        #expect(fixture.store.title(for: first) == "make")
        #expect(fixture.store.title(for: second) == "sleep")
        #expect(fixture.store.title(for: elsewhere) == "top")
    }

    @Test func aCustomNameWinsUntilItIsCleared() async throws {
        let fixture = try MobileTerminalFixture()
        let terminal = try await fixture.create()
        fixture.processEvent(id: terminal.id, foreground: nil, last: "npm")
        fixture.store.rename(terminal, to: "  dev server ")
        #expect(fixture.store.title(for: terminal) == "dev server")
        #expect(!fixture.store.hasExitedProcess(terminal))

        fixture.store.rename(terminal, to: "  ")
        #expect(fixture.store.title(for: terminal) == "npm")
        #expect(fixture.store.hasExitedProcess(terminal))
    }

    @Test func customNamesSurviveRelaunchAndEndWithTheirTerminal() async throws {
        let fixture = try MobileTerminalFixture()
        let terminal = try await fixture.create()
        fixture.store.rename(terminal, to: "logs")
        let restored = MobileTerminalStore(connection: fixture.fake, persistence: fixture.persistence)
        #expect(restored.title(for: terminal) == "logs")

        fixture.event(type: "terminal:exit", id: terminal.id)
        #expect(fixture.persistence.loadNames().isEmpty)
    }

    @Test func persistenceIsScopedToTheBackend() async throws {
        let fixture = try MobileTerminalFixture()
        _ = try await fixture.create()
        let other = MobileTerminalPersistence(backendID: BackendID(UUID()), defaults: fixture.defaults)
        #expect(other.load().isEmpty)
    }
}

@MainActor
struct MobileTerminalFixture {
    let fake: FakeConnectionManager
    let store: MobileTerminalStore
    let persistence: MobileTerminalPersistence
    let defaults: UserDefaults

    init() throws {
        let defaults = try #require(UserDefaults(suiteName: "MobileTerminalTests.\(UUID().uuidString)"))
        self.defaults = defaults
        persistence = MobileTerminalPersistence(backendID: BackendID(UUID()), defaults: defaults)
        fake = FakeConnectionManager()
        fake.connectionState = .connected
        fake.responseMap["events.subscribe"] = ["subscriptionId": "mobile-sub"]
        fake.responseMap["events.unsubscribe"] = ["ok": true]
        fake.responseMap["terminal.list"] = ["daemonBootId": "boot", "terminals": []]
        fake.responseMap["terminal.create"] = ["terminalId": "mobile"]
        fake.responseMap["terminal.kill"] = ["ok": true]
        fake.responseMap["terminal.write"] = ["ok": true]
        fake.responseMap["terminal.resize"] = ["ok": true]
        fake.responseMap["terminal.getBuffer"] = ["data": Data("prompt> ".utf8).base64EncodedString()]
        store = MobileTerminalStore(connection: fake, persistence: persistence)
    }

    func create() async throws -> MobileTerminal {
        let terminal = try #require(await store.create(workspaceId: "workspace"))
        list(ids: [terminal.id])
        return terminal
    }

    func list(ids: [String], bootId: String = "boot", fields: [String: Any] = [:]) {
        fake.responseMap["terminal.list"] = [
            "daemonBootId": bootId,
            "terminals": ids.map { id in
                (["id": id, "name": "Terminal", "isExecutingCommand": true] as [String: Any]).merging(fields) { _, new in new }
            }
        ]
    }

    func processEvent(id: String, foreground: String?, last: String?, workspaceId: String = "workspace") {
        fake.deliverEvent(method: "events.event", params: [
            "subscriptionId": "mobile-sub",
            "event": [
                "type": "terminal:process", "workspaceId": workspaceId,
                "data": [
                    "terminalId": id,
                    "foregroundProcess": foreground as Any? ?? NSNull(),
                    "lastProcess": last as Any? ?? NSNull()
                ]
            ]
        ])
    }

    func event(type: String, id: String = "mobile", data: Data = Data(), subscriptionId: String = "mobile-sub") {
        fake.deliverEvent(method: "events.event", params: [
            "subscriptionId": subscriptionId,
            "event": [
                "type": type, "workspaceId": "workspace",
                "data": ["terminalId": id, "chunk": data.base64EncodedString()]
            ]
        ])
    }
}
