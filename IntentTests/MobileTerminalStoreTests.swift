import Foundation
@testable import Intent
import Testing

@MainActor
struct MobileTerminalStoreTests {
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
        #expect(fixture.store.errorMessage != nil)
        #expect(!fixture.fake.didCallMethod("terminal.create"))
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

    func list(ids: [String], bootId: String = "boot") {
        fake.responseMap["terminal.list"] = [
            "daemonBootId": bootId,
            "terminals": ids.map { ["id": $0, "name": "Terminal", "isExecutingCommand": true] }
        ]
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
