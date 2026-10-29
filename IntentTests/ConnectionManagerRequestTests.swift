import Combine
import Foundation
@testable import Intent
import Network
import os
import Testing

extension ConnectionManagerTests {
    static func enablePlaintextLoopback() -> Bool {
        #if DEBUG
        WebSocketConnection.allowsPlaintextLoopbackForTesting.withLock { state in
            let previous = state
            state = true
            return previous
        }
        #else
        // Keep Release tests buildable without enabling a production escape
        // hatch. These fixtures are not evidence of Release transport coverage.
        Issue.record("Plaintext loopback fixtures require DEBUG; run this test with the default configuration")
        return false
        #endif
    }

    static func restorePlaintextLoopback(_ previous: Bool) {
        #if DEBUG
        WebSocketConnection.allowsPlaintextLoopbackForTesting.withLock { $0 = previous }
        #endif
    }

    @Test func webSocketURLRefusesMissingOrBlankFingerprint() {
        for fingerprint in [nil, "", "   "] as [String?] {
            #expect(throws: WebSocketTransportError.self) {
                _ = try WebSocketConnection.makeURL(
                    host: "daemon.local",
                    port: 4242,
                    certFingerprint: fingerprint
                )
            }
            do {
                _ = try WebSocketConnection.makeURL(
                    host: "daemon.local",
                    port: 4242,
                    certFingerprint: fingerprint
                )
            } catch let error as WebSocketTransportError {
                #expect(error.isMissingCertificatePin)
                #expect(!error.isCertificateMismatch)
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    @Test func plaintextLoopbackOverrideNeverReachesRemoteHosts() throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }

        let loopback = try WebSocketConnection.makeURL(
            host: "127.0.0.1",
            port: 4242,
            certFingerprint: nil
        )
        #expect(loopback.absoluteString == "ws://127.0.0.1:4242/ws")

        for host in ["daemon.local", "10.0.0.7"] {
            #expect(throws: WebSocketTransportError.self) {
                _ = try WebSocketConnection.makeURL(
                    host: host,
                    port: 4242,
                    certFingerprint: nil
                )
            }
        }
    }

    @Test func trustedPinNormalizesBlankToNil() {
        #expect(WebSocketConnection.trustedPin(nil) == nil)
        #expect(WebSocketConnection.trustedPin("") == nil)
        #expect(WebSocketConnection.trustedPin(" \n") == nil)
        #expect(WebSocketConnection.trustedPin(" aa:bb ") == "aa:bb")
    }

    @Test func plaintextLoopbackOverrideRestoredWhenSetupThrows() {
        struct SetupFailed: Error {}
        func failingSetup() throws {
            let previous = Self.enablePlaintextLoopback()
            defer { Self.restorePlaintextLoopback(previous) }
            #expect(WebSocketConnection.plaintextLoopbackOverrideActive)
            throw SetupFailed()
        }

        #expect(!WebSocketConnection.plaintextLoopbackOverrideActive)
        #expect(throws: SetupFailed.self) { try failingSetup() }
        #expect(!WebSocketConnection.plaintextLoopbackOverrideActive)
    }

    @Test func pinnedWebSocketURLUsesSecureScheme() throws {
        let url = try WebSocketConnection.makeURL(
            host: "daemon.local",
            port: 4242,
            certFingerprint: "aa:bb"
        )

        #expect(url.absoluteString == "wss://daemon.local:4242/ws")
    }

    @Test func webSocketHeadersCarryBearerAuthOnly() {
        let headers = WebSocketConnection.additionalHeaders(token: "test-token")

        #expect(headers.count == 1)
        #expect(headers[0].name == "Authorization")
        #expect(headers[0].value == "Bearer test-token")
    }

    @Test func certificateFingerprintIsColonSeparatedLowercaseSha256() {
        let expected = "e3:b0:c4:42:98:fc:1c:14:9a:fb:f4:c8:99:6f:b9:24:"
            + "27:ae:41:e4:64:9b:93:4c:a4:95:99:1b:78:52:b8:55"

        #expect(WebSocketConnection.fingerprint(ofCertificate: Data()) == expected)
    }

    @Test func fingerprintMatchIsCaseInsensitive() {
        let pin = ManualTokenEntryViewTests.fixtureIdentityFingerprint
        #expect(WebSocketConnection.fingerprintMatches(pin.uppercased(), pinned: pin))
        #expect(WebSocketConnection.fingerprintMatches(pin, pinned: pin.uppercased()))
        #expect(!WebSocketConnection.fingerprintMatches(pin, pinned: InvitedSessionFixtures.pin))
    }

    // URLSessionWebSocketTask.Message is not Equatable; extract payloads for asserting.
    private func text(of message: URLSessionWebSocketTask.Message?) -> String? {
        if case let .string(value)? = message { return value }
        return nil
    }

    private func data(of message: URLSessionWebSocketTask.Message?) -> Data? {
        if case let .data(value)? = message { return value }
        return nil
    }

    @Test func assemblerReturnsCompleteTextMessageImmediately() throws {
        var assembler = WebSocketConnection.MessageAssembler()

        let message = try assembler.consume(
            kind: .text,
            data: Data("hello".utf8),
            isComplete: true
        )

        #expect(text(of: message) == "hello")
    }

    @Test func assemblerReassemblesFragmentedTextAcrossContinuations() throws {
        var assembler = WebSocketConnection.MessageAssembler()
        // "héllo" with the two-byte UTF-8 encoding of "é" split across
        // fragments — decoding must wait for the complete message.
        let bytes = Array("héllo".utf8)

        #expect(try assembler.consume(
            kind: .text,
            data: Data(bytes[0..<2]),
            isComplete: false
        ) == nil)
        #expect(try assembler.consume(
            kind: .continuation,
            data: Data(bytes[2..<4]),
            isComplete: false
        ) == nil)
        let message = try assembler.consume(
            kind: .continuation,
            data: Data(bytes[4...]),
            isComplete: true
        )

        #expect(text(of: message) == "héllo")
    }

    @Test func assemblerReassemblesFragmentedBinaryMessages() throws {
        var assembler = WebSocketConnection.MessageAssembler()

        #expect(try assembler.consume(
            kind: .binary,
            data: Data([0x01, 0x02]),
            isComplete: false
        ) == nil)
        let message = try assembler.consume(
            kind: .continuation,
            data: Data([0x03]),
            isComplete: true
        )

        #expect(data(of: message) == Data([0x01, 0x02, 0x03]))
    }

    @Test func assemblerDropsStrayContinuationFrames() throws {
        var assembler = WebSocketConnection.MessageAssembler()

        #expect(try assembler.consume(
            kind: .continuation,
            data: Data([0xff]),
            isComplete: true
        ) == nil)
        // A well-formed message afterwards is unaffected.
        let message = try assembler.consume(
            kind: .text,
            data: Data("ok".utf8),
            isComplete: true
        )
        #expect(text(of: message) == "ok")
    }

    @Test func assemblerResetsBetweenMessages() throws {
        var assembler = WebSocketConnection.MessageAssembler()

        let first = try assembler.consume(
            kind: .text,
            data: Data("first".utf8),
            isComplete: true
        )
        let second = try assembler.consume(
            kind: .text,
            data: Data("second".utf8),
            isComplete: true
        )

        #expect(text(of: first) == "first")
        #expect(text(of: second) == "second")
    }

    @Test func assemblerRejectsInvalidUTF8AndResets() throws {
        var assembler = WebSocketConnection.MessageAssembler()

        #expect(throws: WebSocketConnection.MessageAssemblyError.invalidTextEncoding) {
            try assembler.consume(
                kind: .text,
                data: Data([0xe2, 0x82]),
                isComplete: true
            )
        }
        let message = try assembler.consume(
            kind: .text,
            data: Data("valid after failure".utf8),
            isComplete: true
        )

        #expect(text(of: message) == "valid after failure")
    }

    @Test @MainActor func certificateMismatchErrorIncludesReceivedFingerprint() {
        let error = WebSocketTransportError.certificateMismatch(
            host: "daemon.local",
            fingerprint: "de:ad:be:ef"
        )

        #expect(error.isCertificateMismatch)
        #expect(error.localizedDescription.contains("de:ad:be:ef"))
    }

    // MARK: - Host race certificate mismatch collection

    private actor FakeRaceConnection: HostRacingConnection {
        nonisolated let host: String

        init(host: String) { self.host = host }
        func disconnect() {}
    }

    @Test func mixedRaceCollectsLoserMismatchAndStillWins() async {
        // The winner is held until the loser is about to report its mismatch,
        // so the mismatch is not swallowed by an already-settled race.
        let mismatchReported = TestGate()
        let outcome = await ConnectionManager.raceCandidates(
            ["bad.host", "good.host"]
        ) { host -> FakeRaceConnection in
            if host == "bad.host" {
                mismatchReported.open()
                throw WebSocketTransportError.certificateMismatch(
                    host: host,
                    fingerprint: "aa:bb"
                )
            }
            await mismatchReported.wait()
            return FakeRaceConnection(host: host)
        }

        #expect(outcome.winner?.host == "good.host")
        #expect(outcome.failure == nil)
        // The race settles on the first success, so whether the loser's
        // mismatch is on the outcome or reported by the background drain
        // depends on scheduling; either way it must not be swallowed.
        let lateMismatches = await outcome.drain?.value ?? []
        #expect(outcome.mismatches + lateMismatches == [
            HostCertMismatch(host: "bad.host", fingerprint: "aa:bb")
        ])
    }

    @Test func mismatchAfterWinnerSettledIsNotSwallowed() async {
        let outcome = await ConnectionManager.raceCandidates(
            ["good.host", "bad.host"]
        ) { host -> FakeRaceConnection in
            if host == "bad.host" {
                // Released by the loser cancellation that follows the win.
                await suspendUntilCancelled()
                throw WebSocketTransportError.certificateMismatch(
                    host: host,
                    fingerprint: "cc:dd"
                )
            }
            return FakeRaceConnection(host: host)
        }

        #expect(outcome.winner?.host == "good.host")
        // The loser's mismatch lands after the winner settled the race, so it
        // is reported by the background drain rather than the outcome itself.
        let lateMismatches = await outcome.drain?.value ?? []
        #expect(outcome.mismatches + lateMismatches == [
            HostCertMismatch(host: "bad.host", fingerprint: "cc:dd")
        ])
    }
}

extension ConnectionManagerTests {
    @Test func allMismatchRaceFailsWithEveryHostCollected() async {
        let outcome = await ConnectionManager.raceCandidates(
            ["a.host", "b.host"]
        ) { host -> FakeRaceConnection in
            throw WebSocketTransportError.certificateMismatch(
                host: host,
                fingerprint: "ff:\(host)"
            )
        }

        #expect(outcome.winner == nil)
        #expect(Set(outcome.mismatches) == Set([
            HostCertMismatch(host: "a.host", fingerprint: "ff:a.host"),
            HostCertMismatch(host: "b.host", fingerprint: "ff:b.host")
        ]))
        let failure = outcome.failure as? WebSocketTransportError
        #expect(failure?.isCertificateMismatch == true)
        guard case let .certificateMismatches(carried)? = failure else {
            Issue.record("expected aggregate certificate error, got \(String(describing: outcome.failure))")
            return
        }
        #expect(Set(carried) == Set(outcome.mismatches))
    }

    @Test func certFailurePreferredOverGenericFailuresWhenNoWinner() async {
        // Fixed ordering: the generic failure lands before the mismatch.
        let genericFailureReported = TestGate()
        let outcome = await ConnectionManager.raceCandidates(
            ["down.host", "bad.host"]
        ) { host -> FakeRaceConnection in
            if host == "bad.host" {
                await genericFailureReported.wait()
                throw WebSocketTransportError.certificateMismatch(
                    host: host,
                    fingerprint: "ee:ff"
                )
            }
            genericFailureReported.open()
            throw WebSocketTransportError.failed(host: host, message: "unreachable")
        }

        #expect(outcome.winner == nil)
        #expect(outcome.mismatches == [
            HostCertMismatch(host: "bad.host", fingerprint: "ee:ff")
        ])
        let failure = outcome.failure as? WebSocketTransportError
        #expect(failure?.isCertificateMismatch == true)
    }

    @Test @MainActor func recordCertMismatchesAccumulatesLatestFingerprintPerHost() {
        let manager = ConnectionManager.shared
        manager.certMismatches = []
        var received: [[HostCertMismatch]] = []
        let cancellable = manager.certMismatchesPublisher.sink { received.append($0) }

        manager.recordCertMismatches([HostCertMismatch(host: "a", fingerprint: "f1")])
        manager.recordCertMismatches([
            HostCertMismatch(host: "a", fingerprint: "f2"),
            HostCertMismatch(host: "b", fingerprint: "f3")
        ])

        #expect(manager.certMismatches == [
            HostCertMismatch(host: "a", fingerprint: "f2"),
            HostCertMismatch(host: "b", fingerprint: "f3")
        ])
        #expect(received.last == manager.certMismatches)

        manager.certMismatches = []
        withExtendedLifetime(cancellable) {}
    }

    @Test @MainActor func explicitDisconnectClearsCertMismatches() {
        let manager = ConnectionManager.shared
        manager.certMismatches = [HostCertMismatch(host: "a", fingerprint: "f1")]

        manager.disconnect()

        #expect(manager.certMismatches.isEmpty)
    }

    @Test @MainActor func connectToDifferentTargetClearsMismatchesSameTargetKeepsThem() {
        let manager = ConnectionManager.shared
        manager.updateCachedCredentials(
            hosts: ["h1"],
            port: 1234,
            token: "tok",
            certFingerprint: "pin",
            tcAddress: nil
        )
        let seeded = [HostCertMismatch(host: "h1", fingerprint: "f1")]
        manager.certMismatches = seeded

        manager.resetCertMismatchesIfTargetChanged(
            hosts: ["h1"],
            port: 1234,
            certFingerprint: "pin"
        )
        #expect(manager.certMismatches == seeded)

        // Pinned targets are identified by port + pin: a drifted host list
        // (refreshHostRoutes merges daemon-reported IPs post-connect) is the
        // same daemon, so the list survives an app-driven reconnect from the
        // stored record.
        manager.resetCertMismatchesIfTargetChanged(
            hosts: ["h2"],
            port: 1234,
            certFingerprint: "pin"
        )
        #expect(manager.certMismatches == seeded)

        manager.resetCertMismatchesIfTargetChanged(
            hosts: ["h1"],
            port: 1234,
            certFingerprint: "other-pin"
        )
        #expect(manager.certMismatches.isEmpty)

        manager.certMismatches = seeded
        manager.resetCertMismatchesIfTargetChanged(
            hosts: ["h1"],
            port: 5678,
            certFingerprint: "pin"
        )
        #expect(manager.certMismatches.isEmpty)
    }

    @Test @MainActor func pinlessTargetIdentityFallsBackToHostOverlap() {
        let manager = ConnectionManager.shared
        manager.updateCachedCredentials(
            hosts: ["h1", "h2"],
            port: 1234,
            token: "tok",
            certFingerprint: nil,
            tcAddress: nil
        )
        let seeded = [HostCertMismatch(host: "h1", fingerprint: "f1")]
        manager.certMismatches = seeded

        manager.resetCertMismatchesIfTargetChanged(
            hosts: ["h2", "h3"],
            port: 1234,
            certFingerprint: nil
        )
        #expect(manager.certMismatches == seeded)

        manager.resetCertMismatchesIfTargetChanged(
            hosts: ["h4"],
            port: 1234,
            certFingerprint: nil
        )
        #expect(manager.certMismatches.isEmpty)
    }

    // MARK: - Synced-registry credential adoption

    @Test @MainActor func updateCachedCredentialsReplacesReconnectFields() {
        let manager = ConnectionManager.shared
        manager.updateCachedCredentials(
            hosts: ["10.0.0.9", "mac.local"],
            port: 9999,
            token: "tok-rotated",
            certFingerprint: "ff:ee",
            tcAddress: nil
        )
        #expect(manager.hosts == ["10.0.0.9", "mac.local"])
        #expect(manager.port == 9999)
        #expect(manager.token == "tok-rotated")
        #expect(manager.certFingerprint == "ff:ee")
    }

    // MARK: - Invalid message handling

    @Test @MainActor func dispatchInvalidJsonDoesNotCrash() {
        let manager = ConnectionManager.shared
        manager.dispatchMessage("not valid json")
        manager.dispatchMessage("")
        manager.dispatchMessage("{}")
    }
}
