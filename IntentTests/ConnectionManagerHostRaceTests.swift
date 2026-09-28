import Combine
import Foundation
@testable import Intent
import Network
import os
import Testing

extension ConnectionManagerTests {
    private struct CollectionPushRecord {
        let kind: SubscriptionPush.Kind
        let sequence: Int
        let count: Int
    }

    @Test @MainActor func collectionChannelPushesUnaffectedByBuffering() async {
        let manager = ConnectionManager.shared
        var received: [CollectionPushRecord] = []

        // Registered-first (normal collection-channel flow): pushes route live
        manager.registerSubscriptionHandler(id: "col-sub-1") { push in
            let count: Int
            if case let .collectionSnapshot(snapshot) = push.payload {
                count = snapshot.count
            } else {
                count = 0
            }
            received.append(CollectionPushRecord(kind: push.kind, sequence: push.seq, count: count))
        }
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"col-sub-1","kind":"snapshot","seq":0,"snapshot":[{"id":"note-1"},{"id":"note-2"}]}}
        """)
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"col-sub-1","kind":"delta","seq":1,"delta":{"added":[],"updated":[{"id":"note-1"}],"removedIds":[]}}}
        """)
        #expect(received.count == 2)
        #expect(received[0].kind == .snapshot && received[0].sequence == 0 && received[0].count == 2)
        #expect(received[1].kind == .delta && received[1].sequence == 1)
        #expect(!manager.hasBufferedSubscriptionPush(for: "col-sub-1"))

        // Array-shaped (collection) snapshot arriving pre-registration replays intact
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"col-sub-2","kind":"snapshot","seq":0,"snapshot":[{"id":"task-1"}]}}
        """)
        var replayedSnapshotCount = 0
        var replayedSnapshotID: String?
        manager.registerSubscriptionHandler(id: "col-sub-2") { push in
            if case let .collectionSnapshot(snapshot) = push.payload {
                replayedSnapshotCount = snapshot.count
                replayedSnapshotID = snapshot.first?["id"] as? String
            }
        }
        #expect(replayedSnapshotCount == 1)
        #expect(replayedSnapshotID == "task-1")

        // Clean up
        manager.unregisterSubscriptionHandler(id: "col-sub-1")
        manager.unregisterSubscriptionHandler(id: "col-sub-2")
    }

    @Test @MainActor func bufferedChatSnapshotReplayedIntoConversationStore() async {
        let manager = ConnectionManager.shared
        let store = ConversationStore(connectionManager: manager)
        store.setTestChatChannel(subscriptionId: "buf-chat-race")

        // Snapshot + first delta arrive BEFORE the store registers its handler
        // (the seq-0 race this fix addresses)
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{\
        "subscriptionId":"buf-chat-race","kind":"snapshot","seq":0,\
        "snapshot":{"agentId":"agent-1","messages":[{\
        "id":"msg-1","role":"user","contentBlocks":[{\
        "type":"text","id":"msg-1:0","text":"Hello"}],\
        "timestamp":"2026-07-21T01:00:00.000Z"}]}}}
        """)
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{\
        "subscriptionId":"buf-chat-race","kind":"delta","seq":1,\
        "delta":{"added":[{"agentId":"agent-1","messageId":"msg-2",\
        "role":"assistant","block":{"type":"text","id":"msg-2:0","text":"Working"}}],\
        "updated":[],"removedIds":[]}}}
        """)

        // The store registers its handler (as subscribeLiveChat does after the
        // subscribe response resumes) → buffered pushes replay and apply
        manager.registerSubscriptionHandler(id: "buf-chat-race") { [weak store] push in
            store?.handleChatSubscriptionPush(push)
        }

        #expect(store.messages.count == 2)
        #expect(store.messages[0].id == "msg-1")
        #expect(store.messages[1].id == "msg-2")
        #expect(store.messages[1].contentBlocks.first?.resolvedText == "Working")
        #expect(store.isStreaming == true)

        // The channel is seeded correctly: the next live delta continues the
        // sequence without a gap (no resnapshot wiped the seeded state)
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{\
        "subscriptionId":"buf-chat-race","kind":"delta","seq":2,\
        "delta":{"added":[],"updated":[{\
        "agentId":"agent-1","messageId":"msg-2","role":"assistant",\
        "block":{"type":"text","id":"msg-2:0","text":"Working on it."}}],\
        "removedIds":[]}}}
        """)
        #expect(store.messages[1].contentBlocks.first?.resolvedText == "Working on it.")

        // Clean up
        manager.unregisterSubscriptionHandler(id: "buf-chat-race")
    }

    // MARK: - Host route merge (post-connect refresh)

    @Test @MainActor func mergeHostsAppendsNewReportedIps() {
        let merged = ConnectionManager.mergeHosts(
            existing: ["192.168.1.10"],
            reported: ["192.168.1.10", "10.0.0.5", "172.16.0.2"]
        )
        #expect(merged == ["192.168.1.10", "10.0.0.5", "172.16.0.2"])
    }

    @Test @MainActor func mergeHostsKeepsExistingOrderFirstAndNeverDrops() {
        // The user-entered host is not in the daemon-reported list (e.g. a
        // hostname or NAT address) — it must stay, and stay first.
        let merged = ConnectionManager.mergeHosts(
            existing: ["daemon.local", "10.0.0.5"],
            reported: ["10.0.0.5", "192.168.1.10"]
        )
        #expect(merged == ["daemon.local", "10.0.0.5", "192.168.1.10"])
    }

    @Test @MainActor func mergeHostsDedupesAndSkipsEmptyReportedEntries() {
        let merged = ConnectionManager.mergeHosts(
            existing: ["a"],
            reported: ["b", "b", "", "  ", "a", " c "]
        )
        #expect(merged == ["a", "b", "c"])
    }

    @Test @MainActor func mergeHostsWithNoReportedIpsIsUnchanged() {
        #expect(ConnectionManager.mergeHosts(existing: ["a", "b"], reported: []) == ["a", "b"])
    }

    @Test @MainActor func mergeHostsRejectsInvalidReportedHostsAndNormalizesIPv6() {
        let merged = ConnectionManager.mergeHosts(
            existing: ["daemon.local", "[fe80::1]"],
            reported: [
                "192.168.1.10", "2001:db8::1", "fe80::1", "[2001:db8::1]",
                "host.example.com", "my-mac_2.local", "192.168.1.10:4242",
                "evil.com/path", "user@evil.com", "evil.com?x=1", "http://evil.com",
                "[::1", "::1]", "[]", "a b", "", "::::", "2001::db8::1"
            ]
        )
        #expect(merged == [
            "daemon.local", "[fe80::1]", "192.168.1.10", "[2001:db8::1]",
            "host.example.com", "my-mac_2.local"
        ])
    }

    @Test @MainActor func mergeHostsDedupesCaseVariantsOfExistingAndReportedHosts() {
        // ios#341: `seen` was a case-sensitive set, so HOST.local and
        // host.local both survived as separate routes. The stored spelling
        // wins; the first reported spelling wins among new entries.
        let merged = ConnectionManager.mergeHosts(
            existing: ["HOST.local", "[fe80::1]"],
            reported: ["host.local", "Host.Local", "[FE80::1]", "fe80::1", "New-Mac.local", "new-mac.local", "10.0.0.5"]
        )
        #expect(merged == ["HOST.local", "[fe80::1]", "New-Mac.local", "10.0.0.5"])
    }

    @Test @MainActor func mergeHostsRejectsStructurallyInvalidNamesAndAddresses() {
        // ios#341: the character allowlist admitted these; they must not be
        // raced or persisted.
        let merged = ConnectionManager.mergeHosts(
            existing: ["daemon.local"],
            reported: ["a..b", "-bad", "bad-", ".bad", "999.999.999.999", "1.2.3", "256.0.0.1", "10.0.0.5"]
        )
        #expect(merged == ["daemon.local", "10.0.0.5"])
    }

    @Test @MainActor func persistedMergeKeepsStoredHostsSessionDidNotConnectWith() {
        // Reviewer scenario: the stored record holds a NAT hostname the current
        // session didn't connect with. The persisted list is the stored hosts
        // merged with the session's merge result — the NAT hostname survives.
        let storedHosts = ["nat.example.com", "192.168.1.10"]
        let sessionMerged = ConnectionManager.mergeHosts(
            existing: ["192.168.1.10"],
            reported: ["192.168.1.10", "10.0.0.5"]
        )
        #expect(sessionMerged == ["192.168.1.10", "10.0.0.5"])

        let persisted = ConnectionManager.mergeHosts(existing: storedHosts, reported: sessionMerged)
        #expect(persisted == ["nat.example.com", "192.168.1.10", "10.0.0.5"])
    }

    // MARK: - localIps parsing (system.status)

    @Test @MainActor func localIpsParsedFromSystemStatusResult() {
        let result: [String: Any] = [
            "version": "1.2.3",
            "hostname": "mac.local",
            "localIps": ["192.168.1.10", "10.0.0.5"]
        ]
        #expect(ConnectionManager.localIps(fromSystemStatus: result) == .value(["192.168.1.10", "10.0.0.5"]))
    }

    @Test @MainActor func localIpsNilWhenFieldAbsentOnOlderDaemon() {
        let result: [String: Any] = ["version": "1.0.0"]
        #expect(ConnectionManager.localIps(fromSystemStatus: result) == .unavailable)
    }

    @Test @MainActor func localIpsNilWhenMalformed() {
        #expect(ConnectionManager.localIps(fromSystemStatus: ["localIps": "not-an-array"]) == .unavailable)
        #expect(ConnectionManager.localIps(fromSystemStatus: ["localIps": [1, 2]]) == .unavailable)
        #expect(ConnectionManager.localIps(fromSystemStatus: "not-a-dict") == .unavailable)
        #expect(ConnectionManager.localIps(fromSystemStatus: NSNull()) == .unavailable)
    }

    @Test @MainActor func hostRouteRefreshDecisionRejectsFailedStatusRequest() {
        let response: Result<Any, Error> = .failure(
            NSError(domain: "test", code: 1)
        )

        #expect(ConnectionManager.hostRouteRefreshDecision(
            response: response,
            requestedGeneration: 4,
            currentGeneration: 4
        ) == .failed)
    }

    @Test @MainActor func hostRouteRefreshDecisionRejectsStaleStatusResponse() {
        let response: Result<Any, Error> = .success([
            "localIps": ["10.0.0.5"],
            "tcAddress": "tc-stale"
        ])

        #expect(ConnectionManager.hostRouteRefreshDecision(
            response: response,
            requestedGeneration: 4,
            currentGeneration: 5
        ) == .stale)
    }

    @Test @MainActor func hostRouteRefreshDecisionCarriesCurrentRoutes() {
        let response: Result<Any, Error> = .success([
            "localIps": ["10.0.0.5"],
            "tcAddress": " tc-current "
        ])

        #expect(ConnectionManager.hostRouteRefreshDecision(
            response: response,
            requestedGeneration: 5,
            currentGeneration: 5
        ) == .current(localIps: .value(["10.0.0.5"]), tcAddress: "tc-current"))
    }

    // MARK: - tcAddress parsing (system.status)

    @Test @MainActor func tcAddressParsedFromSystemStatusResult() {
        let result: [String: Any] = [
            "version": "1.2.3",
            "tcAddress": "tc-abcdef123456"
        ]
        #expect(ConnectionManager.tcAddress(fromSystemStatus: result) == "tc-abcdef123456")
    }

    @Test @MainActor func tcAddressNilWhenAbsentMalformedOrBlank() {
        #expect(ConnectionManager.tcAddress(fromSystemStatus: ["version": "1.0.0"]) == nil)
        #expect(ConnectionManager.tcAddress(fromSystemStatus: ["tcAddress": 42]) == nil)
        #expect(ConnectionManager.tcAddress(fromSystemStatus: ["tcAddress": "  "]) == nil)
        #expect(ConnectionManager.tcAddress(fromSystemStatus: "not-a-dict") == nil)
    }

    @Test @MainActor func updateCachedCredentialsAdoptsTcAddress() {
        let manager = ConnectionManager.shared
        manager.updateCachedCredentials(
            hosts: ["h1"],
            port: 1,
            token: "t",
            certFingerprint: nil,
            tcAddress: "tc-tunnel-token"
        )
        #expect(manager.tcAddress == "tc-tunnel-token")
        manager.updateCachedCredentials(
            hosts: ["h1"],
            port: 1,
            token: "t",
            certFingerprint: nil,
            tcAddress: nil
        )
        #expect(manager.tcAddress == nil)
    }

    // MARK: - Tunnel race candidate

    nonisolated final class FakeTunnelSession: TunnelSession, @unchecked Sendable {
        let localPort: Int
        let closed = OSAllocatedUnfairLock(initialState: false)

        init(localPort: Int) { self.localPort = localPort }
        func close() async { closed.withLock { $0 = true } }

        var isClosed: Bool { closed.withLock { $0 } }
    }

    nonisolated struct FakeTunnelDialer: TunnelDialing {
        let result: Result<FakeTunnelSession, WebSocketTransportError>

        func open(tcAddress _: String, remotePort _: Int) async throws -> any TunnelSession {
            try result.get()
        }
    }

    /// Platforms without a TailcatKit build (visionOS) default to
    /// `UnavailableTunnelDialer`: a tunnel candidate fails with the clear
    /// unavailable error, labeled to the tunnel route, instead of crashing.
    @Test func unavailableTunnelDialerFailsWithClearError() async {
        let outcome = await ConnectionManager.raceCandidates([ConnectionManager.tunnelCandidateLabel]) { _ in
            try await ConnectionManager.connectViaTunnel(
                dialer: UnavailableTunnelDialer(),
                tcAddress: "tc-x",
                remotePort: 5181,
                token: "t",
                certFingerprint: nil
            )
        }
        guard let error = outcome.failure as? WebSocketTransportError,
              case let .failed(host, message, _) = error else {
            Issue.record("expected the original tunnel transport failure")
            return
        }
        #expect(host == ConnectionManager.tunnelCandidateLabel)
        #expect(message == UnavailableTunnelDialer.unavailableMessage)
    }

    /// A failed tunnel dial surfaces as a candidate failure with the tunnel
    /// label (not a raw loopback host).
}

extension ConnectionManagerTests {
    @Test func tunnelDialFailurePropagates() async {
        let dialer = FakeTunnelDialer(
            result: .failure(.failed(
                host: ConnectionManager.tunnelCandidateLabel,
                message: "no derp"
            ))
        )
        let outcome = await ConnectionManager.raceCandidates([ConnectionManager.tunnelCandidateLabel]) { _ in
            try await ConnectionManager.connectViaTunnel(
                dialer: dialer,
                tcAddress: "tc-x",
                remotePort: 5181,
                token: "t",
                certFingerprint: nil
            )
        }
        #expect(outcome.failure is WebSocketTransportError)
    }

    /// When the tunnel establishes but the WSS handshake through it fails,
    /// the session must be closed (no leaked tunnel from a dead candidate).
    @Test func tunnelClosedWhenSocketHandshakeFails() async {
        // Port 1 on loopback: connection refused, fast deterministic failure.
        // Pinned so the failure is the handshake itself, not pin admission.
        let tunnel = FakeTunnelSession(localPort: 1)
        let dialer = FakeTunnelDialer(result: .success(tunnel))
        await #expect(throws: (any Error).self) {
            _ = try await ConnectionManager.connectViaTunnel(
                dialer: dialer,
                tcAddress: "tc-x",
                remotePort: 5181,
                token: "t",
                certFingerprint: "aa:bb"
            )
        }
        #expect(tunnel.isClosed)
    }

    @Test func tunnelRefusesPinlessSocketAndCloses() async {
        let tunnel = FakeTunnelSession(localPort: 1)
        let dialer = FakeTunnelDialer(result: .success(tunnel))
        do {
            _ = try await ConnectionManager.connectViaTunnel(
                dialer: dialer,
                tcAddress: "tc-x",
                remotePort: 5181,
                token: "t",
                certFingerprint: nil
            )
            Issue.record("expected connectViaTunnel to refuse a pin-less record")
        } catch let error as WebSocketTransportError {
            guard case let .missingCertificatePin(host) = error else {
                Issue.record("unexpected transport error: \(error)")
                return
            }
            #expect(host == ConnectionManager.tunnelCandidateLabel)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(tunnel.isClosed)
    }

    /// A raced candidate that mirrors `RacedConnection`: `disconnect()` closes
    /// the carried tunnel session, so loser cleanup releases tunnel resources.
    nonisolated private struct FakeTunnelRaceConnection: HostRacingConnection {
        let host: String
        let tunnel: FakeTunnelSession?

        func disconnect() async {
            await tunnel?.close()
        }
    }

    /// When a direct host wins the race, the LOSING tunnel candidate's session
    /// must be closed by `raceCandidates` loser cleanup (no leaked tunnel).
    /// The tunnel candidate holds its lane until the win cancels it, so it
    /// always completes as a late success.
    @Test func losingTunnelCandidateSessionClosedWhenDirectHostWins() async {
        let tunnel = FakeTunnelSession(localPort: 1)
        let outcome = await ConnectionManager.raceCandidates(
            ["direct.host", ConnectionManager.tunnelCandidateLabel]
        ) { host -> FakeTunnelRaceConnection in
            if host == ConnectionManager.tunnelCandidateLabel {
                await suspendUntilCancelled()
                return FakeTunnelRaceConnection(host: host, tunnel: tunnel)
            }
            return FakeTunnelRaceConnection(host: host, tunnel: nil)
        }

        #expect(outcome.winner?.host == "direct.host")
        _ = await outcome.drain?.value
        #expect(tunnel.isClosed)
    }

    /// Regression: the race must settle as soon as a candidate wins instead of
    /// waiting for every loser to finish. A loser that ignores cancellation
    /// (a tunnel dial whose Go side does not abort promptly) must not delay
    /// the connect, and must still be disconnected by the background drain.
    /// The loser is released only after the race has returned, so a race that
    /// waited on it would hit the time limit instead of racing a stopwatch;
    /// the time limit's cancellation of the test opens the gate so that
    /// regression fails instead of hanging.
    @Test(.timeLimit(.minutes(1)))
    func raceSettlesOnWinnerWithoutWaitingForUncancellableLoser() async {
        let loserTunnel = FakeTunnelSession(localPort: 1)
        let loserRelease = TestGate()
        let outcome = await loserRelease.opening {
            await ConnectionManager.raceCandidates(
                ["direct.host", ConnectionManager.tunnelCandidateLabel]
            ) { host -> FakeTunnelRaceConnection in
                if host == ConnectionManager.tunnelCandidateLabel {
                    // `TestGate.wait()` is not interrupted by the candidate
                    // task's cancellation.
                    await loserRelease.wait()
                    return FakeTunnelRaceConnection(host: host, tunnel: loserTunnel)
                }
                return FakeTunnelRaceConnection(host: host, tunnel: nil)
            }
        }

        #expect(outcome.winner?.host == "direct.host")
        #expect(outcome.failure == nil)
        // The loser is still in flight; cleanup happens off the critical path.
        #expect(!loserTunnel.isClosed)
        loserRelease.open()
        _ = await outcome.drain?.value
        #expect(loserTunnel.isClosed)
    }
}
