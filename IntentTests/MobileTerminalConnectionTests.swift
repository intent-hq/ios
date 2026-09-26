import Foundation
@testable import Intent
import Testing

@MainActor
struct MobileTerminalConnectionTests {
    @Test func openingAndDismissingAnExistingSessionNeverCreatesOrKills() async throws {
        let fixture = try MobileTerminalFixture()
        let terminal = try await fixture.create()
        fixture.fake.clearRequestLog()
        let connection = MobileTerminalConnection(store: fixture.store, terminal: terminal)
        var output = Data()
        connection.outputHandler = { data, _ in output.append(data) }
        await connection.attach()
        #expect(connection.isReady)
        #expect(output == Data("prompt> ".utf8))
        connection.detach()
        #expect(!fixture.fake.didCallMethod("terminal.create"))
        #expect(!fixture.fake.didCallMethod("terminal.kill"))
        #expect(fixture.store.activeTerminals(workspaceId: "workspace") == [terminal])
    }

    @Test func outputIsBinarySafeAndFilteredToTheSelectedTerminalAndSubscription() async throws {
        let fixture = try MobileTerminalFixture()
        let terminal = try await fixture.create()
        let connection = MobileTerminalConnection(store: fixture.store, terminal: terminal)
        await connection.attach()
        var output = Data()
        connection.outputHandler = { data, _ in output.append(data) }
        let bytes = Data([0, 255, 27, 91])
        fixture.event(type: "terminal:data", data: bytes)
        fixture.event(type: "terminal:data", id: "desktop", data: bytes)
        fixture.event(type: "terminal:data", data: bytes, subscriptionId: "other")
        #expect(output == bytes)
        connection.detach()
    }

    @Test func inputIsSerializedAndEncodedWithoutReordering() async throws {
        let fixture = try MobileTerminalFixture()
        let terminal = try await fixture.create()
        let connection = MobileTerminalConnection(store: fixture.store, terminal: terminal)
        await connection.attach()
        fixture.fake.pendingMethods.insert("terminal.write")
        connection.send(Data("a".utf8))
        try await fixture.fake.waitForPendingRequests("terminal.write")
        connection.send(Data("b".utf8))
        connection.send(Data("c".utf8))
        fixture.fake.resolvePending("terminal.write", with: ["ok": true])
        try await fixture.fake.waitForPendingRequests("terminal.write")
        let payloads = fixture.fake.paramsForMethod("terminal.write").compactMap { $0["data"] as? String }
        #expect(payloads == [Data("a".utf8).base64EncodedString(), Data("bc".utf8).base64EncodedString()])
        fixture.fake.resolvePending("terminal.write", with: ["ok": true])
        connection.detach()
    }

    @Test func disconnectDropsQueuedInputAndDoesNotResendItAfterReconnect() async throws {
        let fixture = try MobileTerminalFixture()
        let terminal = try await fixture.create()
        let connection = MobileTerminalConnection(store: fixture.store, terminal: terminal)
        await connection.attach()
        fixture.fake.connectionState = .disconnected
        connection.send(Data("dangerous command\n".utf8))
        fixture.fake.connectionState = .connected
        connection.send(Data("another command\n".utf8))
        await connection.attach()
        #expect(!fixture.fake.didCallMethod("terminal.write"))
        connection.detach()
    }

    @Test func daemonRestartPreventsAttachingToAReusedId() async throws {
        let fixture = try MobileTerminalFixture()
        let terminal = try await fixture.create()
        fixture.list(ids: [terminal.id], bootId: "new-boot")
        let connection = MobileTerminalConnection(store: fixture.store, terminal: terminal)
        await connection.attach()
        #expect(!connection.isReady)
        #expect(connection.errorMessage != nil)
        #expect(!fixture.fake.didCallMethod("terminal.getBuffer"))
    }

    @Test func detachingDuringReplayDoesNotDeliverOutputOrBecomeReady() async throws {
        let fixture = try MobileTerminalFixture()
        let terminal = try await fixture.create()
        let connection = MobileTerminalConnection(store: fixture.store, terminal: terminal)
        fixture.fake.pendingMethods.insert("terminal.getBuffer")
        var delivered = false
        connection.outputHandler = { _, _ in delivered = true }
        let attach = Task { await connection.attach() }
        try await fixture.fake.waitForPendingRequests("terminal.getBuffer")
        connection.detach()
        fixture.fake.resolvePending("terminal.getBuffer", with: ["data": Data("old".utf8).base64EncodedString()])
        await attach.value
        #expect(!delivered)
        #expect(!connection.isReady)
    }

    @Test func bufferedLiveOutputIsAppendedOnceWhenItOverlapsReplay() async throws {
        let fixture = try MobileTerminalFixture()
        let terminal = try await fixture.create()
        let connection = MobileTerminalConnection(store: fixture.store, terminal: terminal)
        fixture.fake.pendingMethods.insert("terminal.getBuffer")
        var output = Data()
        connection.outputHandler = { data, _ in output.append(data) }
        let attach = Task { await connection.attach() }
        try await fixture.fake.waitForPendingRequests("terminal.getBuffer")
        fixture.event(type: "terminal:data", data: Data("prompt> newer".utf8))
        fixture.fake.resolvePending("terminal.getBuffer", with: ["data": Data("history\nprompt> ".utf8).base64EncodedString()])
        await attach.value
        #expect(output == Data("history\nprompt> newer".utf8))
        connection.detach()
    }

    @Test(arguments: [
        ("", "abc", "abc"), ("abc", "", "abc"), ("abc", "xyz", "abcxyz"),
        ("abc", "abc", "abc"), ("abc", "bcdef", "abcdef"), ("aaaa", "aaab", "aaaab")
    ])
    func replayHandlesEmptyAndOverlappingChunks(snapshot: String, pending: String, expected: String) {
        #expect(MobileTerminalConnection.replay(snapshot: Data(snapshot.utf8), pending: Data(pending.utf8)) == Data(expected.utf8))
    }
}
