import Foundation
@testable import Intent
import Observation
import SwiftTerm
import SwiftUI
import Testing
import UIKit

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

    @Test(arguments: [false, true])
    func hiddenRetainedTerminalResignsFocusAndRejectsInput(duringAttachment: Bool) async throws {
        let fixture = try MobileTerminalFixture()
        let terminal = try await fixture.create()
        let visibility = TerminalTestVisibility()
        if duringAttachment { fixture.fake.pendingMethods.insert("terminal.getBuffer") }
        let pane = RetainedTerminalTestPane(terminal: terminal, store: fixture.store, visibility: visibility)
        try await SyntheticBadgeHost.render(pane, width: 800, height: 600) { host, window in
            let previousKey = window.windowScene?.keyWindow
            window.makeKey()
            defer {
                window.endEditing(true)
                previousKey?.makeKey()
            }
            try await verifyRetainedTerminal(in: host, fixture: fixture, visibility: visibility, duringAttachment: duringAttachment)
        }
    }

    private func verifyRetainedTerminal(
        in host: UIView, fixture: MobileTerminalFixture, visibility: TerminalTestVisibility, duringAttachment: Bool
    ) async throws {
        if duringAttachment {
            try await fixture.fake.waitForPendingRequests("terminal.getBuffer")
        } else {
            try await waitUntil("terminal accepts input") { Self.canvas(in: host)?.isUserInteractionEnabled == true }
        }
        let canvas = try #require(Self.canvas(in: host))
        if !duringAttachment {
            #expect(canvas.becomeFirstResponder())
            #expect(canvas.isFirstResponder)
        }
        visibility.isVisible = false
        try await waitUntil("covered terminal relinquishes input") {
            !canvas.isUserInteractionEnabled && !canvas.isFirstResponder
        }
        if duringAttachment {
            fixture.fake.pendingMethods.remove("terminal.getBuffer")
            fixture.fake.resolvePending("terminal.getBuffer", with: ["data": Data("late replay".utf8).base64EncodedString()])
        }
        #expect(!canvas.becomeFirstResponder())
        canvas.send(txt: "hidden command\n")
        try await waitUntil("covered terminal detaches") { fixture.fake.didCallMethod("events.unsubscribe") }
        #expect(!canvas.isFirstResponder)
        #expect(!fixture.fake.didCallMethod("terminal.write"))
        #expect(!fixture.fake.didCallMethod("terminal.kill"))
        visibility.isVisible = true
        try await waitUntil("uncovered terminal reattaches") { canvas.isUserInteractionEnabled }
        #expect(Self.canvas(in: host) === canvas)
        canvas.send(txt: "visible command\n")
        try await waitUntil("visible terminal sends input") { fixture.fake.didCallMethod("terminal.write") }
        #expect(fixture.fake.paramsForMethod("terminal.write").compactMap { $0["data"] as? String }
            == [Data("visible command\n".utf8).base64EncodedString()])
    }

    private static func canvas(in host: UIView) -> TerminalCanvasView? {
        if let canvas = host as? TerminalCanvasView { return canvas }
        return host.subviews.lazy.compactMap { canvas(in: $0) }.first
    }

    @Test(arguments: [
        ("", "abc", "abc"), ("abc", "", "abc"), ("abc", "xyz", "abcxyz"),
        ("abc", "abc", "abc"), ("abc", "bcdef", "abcdef"), ("aaaa", "aaab", "aaaab")
    ])
    func replayHandlesEmptyAndOverlappingChunks(snapshot: String, pending: String, expected: String) {
        #expect(MobileTerminalConnection.replay(snapshot: Data(snapshot.utf8), pending: Data(pending.utf8)) == Data(expected.utf8))
    }
}

@MainActor @Observable private final class TerminalTestVisibility {
    var isVisible = true
}

private struct RetainedTerminalTestPane: View {
    let terminal: MobileTerminal
    let store: MobileTerminalStore
    let visibility: TerminalTestVisibility

    var body: some View {
        MobileTerminalView(terminal: terminal, workspaceName: "Workspace", store: store) {}
            .environment(\.isIPadPaneVisible, visibility.isVisible)
            .environment(\.scenePhase, .active)
    }
}
