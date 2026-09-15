import Combine
import Foundation
import Network
import os
import Testing
@testable import Intent

@Suite(.serialized)
struct ConnectionManagerTests {
    private final class ResponseCapture {
        var value: Any?
        var error: (any Error)?
    }

    // MARK: - ConnectionState equality

    @Test @MainActor func connectionStateDisconnectedEquality() {
        #expect(ConnectionState.disconnected == ConnectionState.disconnected)
    }

    @Test @MainActor func connectionStateConnectedEquality() {
        #expect(ConnectionState.connected == ConnectionState.connected)
    }

    @Test @MainActor func connectionStateConnectingEquality() {
        #expect(ConnectionState.connecting == ConnectionState.connecting)
    }

    @Test @MainActor func connectionStateReconnectingSameAttempt() {
        #expect(ConnectionState.reconnecting(attempt: 1) == ConnectionState.reconnecting(attempt: 1))
    }

    @Test @MainActor func connectionStateReconnectingDifferentAttempt() {
        #expect(ConnectionState.reconnecting(attempt: 1) != ConnectionState.reconnecting(attempt: 2))
    }

    @Test @MainActor func connectionStateDifferentCases() {
        #expect(ConnectionState.connected != ConnectionState.disconnected)
        #expect(ConnectionState.connecting != ConnectionState.connected)
        #expect(ConnectionState.reconnecting(attempt: 1) != ConnectionState.connected)
    }

    @Test @MainActor func observableStateKeepsCombineBridgesInSync() {
        let manager = ConnectionManager.shared
        let originalConnectionState = manager.connectionState
        let originalCertMismatch = manager.certMismatchDetected
        var receivedConnectionStates: [ConnectionState] = []
        var receivedCertMismatches: [Bool] = []

        let connectionCancellable = manager.connectionStatePublisher.sink {
            receivedConnectionStates.append($0)
        }
        let certCancellable = manager.certMismatchPublisher.sink {
            receivedCertMismatches.append($0)
        }

        manager.connectionState = .connecting
        manager.certMismatchDetected = true

        #expect(receivedConnectionStates.last == .connecting)
        #expect(receivedCertMismatches.last == true)

        manager.connectionState = originalConnectionState
        manager.certMismatchDetected = originalCertMismatch
        withExtendedLifetime((connectionCancellable, certCancellable)) {}
    }

    @Test @MainActor func shortLivedConnectionCarriesReconnectBackoffForward() {
        #expect(ConnectionManager.reconnectStartingAttempt(
            connectionLifetime: nil, previousAttempt: 4) == 1)
        #expect(ConnectionManager.reconnectStartingAttempt(
            connectionLifetime: 10, previousAttempt: 4) == 1)
        #expect(ConnectionManager.reconnectStartingAttempt(
            connectionLifetime: 9.9, previousAttempt: 0) == 2)
        #expect(ConnectionManager.reconnectStartingAttempt(
            connectionLifetime: 1, previousAttempt: 4) == 5)
    }

    // MARK: - Event handlers

    @Test @MainActor func onEventRegistersHandler() async {
        let manager = ConnectionManager.shared
        let initialCount = manager.eventHandlers.count
        let handlerId = manager.onEvent { _, _ in }
        #expect(manager.eventHandlers.count == initialCount + 1)
        // Clean up: remove the handler we added
        manager.removeEventHandler(id: handlerId)
    }

    @Test @MainActor func eventHandlerReceivesEvents() async {
        let manager = ConnectionManager.shared
        var receivedMethod: String?
        var receivedParams: Any?
        let handlerId = manager.onEvent { method, params in
            receivedMethod = method
            receivedParams = params
        }

        let notification = """
        {"jsonrpc":"2.0","method":"events.event","params":{"type":"workspace:updated","data":{"id":"ws-1"}}}
        """
        manager.dispatchMessage(notification)

        #expect(receivedMethod == "events.event")
        #expect(receivedParams != nil)
        // Clean up
        manager.removeEventHandler(id: handlerId)
    }

    // MARK: - Message dispatch (response routing)

    @Test @MainActor func dispatchResponseResolvesCorrectContinuation() async throws {
        let manager = ConnectionManager.shared

        let (expectation, capture) = installPendingResponse(manager, id: 999)

        try? await Task.sleep(nanoseconds: 10_000_000) // let Task store continuation

        let response = """
        {"jsonrpc":"2.0","id":999,"result":{"workspaces":[]}}
        """
        manager.dispatchMessage(response)

        await expectation.value
        #expect(capture.value is [String: Any])
    }

    @Test @MainActor func dispatchErrorResponseRejectsContinuation() async {
        let manager = ConnectionManager.shared

        let (expectation, capture) = installPendingResponse(manager, id: 888)

        try? await Task.sleep(nanoseconds: 10_000_000) // let Task store continuation

        let errorResponse = """
        {"jsonrpc":"2.0","id":888,"error":{"code":-1,"message":"Something went wrong"}}
        """
        manager.dispatchMessage(errorResponse)

        await expectation.value
        if let error = capture.error {
            #expect(error.localizedDescription.contains("Something went wrong"))
        } else {
            Issue.record("Expected error but got success")
        }
    }

    // MARK: - Request timeout (per-call override)

    @Test @MainActor func defaultRequestTimeoutIsTenSeconds() {
        #expect(ConnectionManager.defaultRequestTimeout == 10)
    }

    /// Regression (PR #94 review): a daemon that NEVER responds must still
    /// produce the timeout error. Previously the timeout child's throw left
    /// the task group awaiting the suspended continuation child (which does
    /// not observe cancellation), hanging the request forever.
    @Test @MainActor func timeoutFiresWhenDaemonNeverResponds() async {
        let manager = ConnectionManager.shared
        let start = ContinuousClock.now
        do {
            _ = try await manager.awaitResponse(id: 7003, timeout: 0.05, write: { nil })
            Issue.record("Expected timeout error but got success")
        } catch {
            #expect(error.localizedDescription.contains("timed out"))
        }
        #expect(ContinuousClock.now - start < .seconds(5))
        // Pending continuation is cleaned up by the timeout path itself
        #expect(manager.pendingRequests[7003] == nil)
    }

    /// Regression (#1954): the request timeout was hardcoded to 10s with no
    /// per-call override. A short per-call timeout must fire at the configured
    /// bound — well before the 10s default would. A response landing after the
    /// timeout has already fired is ignored; the timeout error wins.
    @Test @MainActor func perCallTimeoutFiresAtConfiguredBound() async {
        let manager = ConnectionManager.shared
        let start = ContinuousClock.now
        let capture = ResponseCapture()
        let pending = Task { @MainActor in
            do {
                capture.value = try await manager.awaitResponse(id: 7001, timeout: 0.05, write: { nil })
            } catch {
                capture.error = error
            }
        }
        await waitForPendingRequest(manager, id: 7001)

        try? await Task.sleep(nanoseconds: 200_000_000) // let the 0.05s timeout fire
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","id":7001,"result":{"late":true}}
        """)

        await pending.value
        if let error = capture.error {
            #expect(error.localizedDescription.contains("timed out"))
        } else {
            Issue.record("Expected timeout error but got success")
        }
        #expect(ContinuousClock.now - start < .seconds(5))
        // Pending continuation is cleaned up
        #expect(manager.pendingRequests[7001] == nil)
    }

    /// A response arriving after a delay but within the per-call override must
    /// resolve the request instead of timing out (the daemon's structured
    /// result wins over the client-side transport timeout).
    @Test @MainActor func perCallTimeoutOverrideHonored() async throws {
        let manager = ConnectionManager.shared
        let capture = ResponseCapture()
        let pending = Task { @MainActor in
            do {
                capture.value = try await manager.awaitResponse(id: 7002, timeout: 5.0, write: { nil })
            } catch {
                capture.error = error
            }
        }
        await waitForPendingRequest(manager, id: 7002)

        try? await Task.sleep(nanoseconds: 100_000_000) // outlast a hypothetical short bound
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","id":7002,"result":{"ok":true}}
        """)

        await pending.value
        #expect(capture.error == nil)
        #expect(capture.value is [String: Any])
        #expect(manager.pendingRequests[7002] == nil)
    }

    @Test @MainActor func cancellingRequestCancelsWriteAndRemovesPendingResponse() async {
        let manager = ConnectionManager.shared
        let writeCancelled = OSAllocatedUnfairLock(initialState: false)
        let capture = ResponseCapture()
        let pending = Task { @MainActor in
            do {
                capture.value = try await manager.awaitResponse(id: 7004, timeout: 5.0) {
                    Task {
                        do {
                            try await Task.sleep(for: .seconds(5))
                        } catch is CancellationError {
                            writeCancelled.withLock { $0 = true }
                        } catch {}
                    }
                }
            } catch {
                capture.error = error
            }
        }
        await waitForPendingRequest(manager, id: 7004)

        pending.cancel()
        await pending.value
        if capture.error is CancellationError {
        } else if let error = capture.error {
            Issue.record("Expected CancellationError, got \(error)")
        } else {
            Issue.record("Expected cancellation")
        }
        let cancellationDeadline = ContinuousClock.now + .seconds(5)
        while !writeCancelled.withLock({ $0 }) {
            if ContinuousClock.now >= cancellationDeadline {
                Issue.record("Timed out waiting for the write task to observe cancellation")
                break
            }
            await Task.yield()
        }

        #expect(manager.pendingRequests[7004] == nil)
        #expect(writeCancelled.withLock { $0 })
    }

    /// Deterministically wait (bounded) until the continuation-registration Task
    /// has stored its continuation, instead of a fixed sleep (flake-prone under
    /// CI load). The registration Task inherits the main actor, so yielding here
    /// lets it run to the registration point.
    @MainActor
    private func installPendingResponse(
        _ manager: ConnectionManager,
        id: Int
    ) -> (Task<Void, Never>, ResponseCapture) {
        let capture = ResponseCapture()
        let task = Task { @MainActor in
            do {
                capture.value = try await withCheckedThrowingContinuation { continuation in
                    manager.pendingRequests[id] = continuation
                }
            } catch {
                capture.error = error
            }
        }
        return (task, capture)
    }

    @MainActor
    private func waitForPendingRequest(_ manager: ConnectionManager, id: Int) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while manager.pendingRequests[id] == nil {
            if ContinuousClock.now >= deadline {
                Issue.record("Timed out waiting for pendingRequests[\(id)] to be registered")
                return
            }
            await Task.yield()
        }
    }

    @Test @MainActor func dispatchErrorResponsePreservesDataCode() async {
        let manager = ConnectionManager.shared

        let (expectation, capture) = installPendingResponse(manager, id: 889)

        await waitForPendingRequest(manager, id: 889)

        let errorResponse = """
        {"jsonrpc":"2.0","id":889,"error":{"code":-32602,"message":"unknown agent id: gone","data":{"code":"not-found"}}}
        """
        manager.dispatchMessage(errorResponse)

        await expectation.value
        if let error = capture.error {
            let nsError = error as NSError
            #expect(nsError.domain == "WebSocket")
            #expect(nsError.code == -32602)
            #expect(nsError.intentErrorDataCode == "not-found")
            #expect(nsError.isEntityNotFound)
        } else {
            Issue.record("Expected error but got success")
        }
    }

    @Test @MainActor func dispatchErrorResponseWithoutDataOmitsDataCode() async {
        let manager = ConnectionManager.shared

        let (expectation, capture) = installPendingResponse(manager, id: 890)

        await waitForPendingRequest(manager, id: 890)

        // Legacy daemons emit -32602 with no data (monorepo#1365)
        let errorResponse = """
        {"jsonrpc":"2.0","id":890,"error":{"code":-32602,"message":"unknown agent id: gone"}}
        """
        manager.dispatchMessage(errorResponse)

        await expectation.value
        if let error = capture.error {
            let nsError = error as NSError
            #expect(nsError.code == -32602)
            #expect(nsError.intentErrorDataCode == nil)
            #expect(!nsError.isEntityNotFound, "a -32602 without data.code must not read as entity-not-found")
        } else {
            Issue.record("Expected error but got success")
        }
    }

    // MARK: - NSError.isEntityNotFound helper

    @Test func isEntityNotFoundRequiresDomainCodeAndDataCode() {
        let notFound = NSError(
            domain: "WebSocket", code: -32602,
            userInfo: [NSError.intentErrorDataCodeKey: "not-found"])
        #expect(notFound.isEntityNotFound)

        let invalidParams = NSError(
            domain: "WebSocket", code: -32602,
            userInfo: [NSError.intentErrorDataCodeKey: "invalid-params"])
        #expect(!invalidParams.isEntityNotFound)

        let bare = NSError(domain: "WebSocket", code: -32602)
        #expect(!bare.isEntityNotFound)

        let wrongCode = NSError(
            domain: "WebSocket", code: -32603,
            userInfo: [NSError.intentErrorDataCodeKey: "not-found"])
        #expect(!wrongCode.isEntityNotFound)

        let wrongDomain = NSError(
            domain: "SomeOtherDomain", code: -32602,
            userInfo: [NSError.intentErrorDataCodeKey: "not-found"])
        #expect(!wrongDomain.isEntityNotFound)
    }

    // MARK: - failAllPending

    @Test @MainActor func failAllPendingClearsRequests() async {
        let manager = ConnectionManager.shared

        let (task1, capture1) = installPendingResponse(manager, id: 100)
        let (task2, capture2) = installPendingResponse(manager, id: 101)

        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms

        manager.failAllPending(error: "Connection lost")

        #expect(manager.pendingRequests.isEmpty)

        await task1.value
        if let error = capture1.error {
            #expect(error.localizedDescription.contains("Connection lost"))
        } else {
            Issue.record("Expected error")
        }
        await task2.value
        if let error = capture2.error {
            #expect(error.localizedDescription.contains("Connection lost"))
        } else {
            Issue.record("Expected error")
        }
    }

    /// ios#251: a record without a trusted pin must never select ws:// — the
    /// URL builder refuses instead of downgrading, so no socket carrying the
    /// bearer header can open in the clear. Empty/blank pins (legacy and
    /// synced records) count as missing.
    @Test func webSocketURLRefusesMissingOrBlankFingerprint() {
        for fingerprint in [nil, "", "   "] as [String?] {
            #expect(throws: WebSocketTransportError.self) {
                _ = try WebSocketConnection.makeURL(
                    host: "daemon.local", port: 4242, certFingerprint: fingerprint)
            }
            do {
                _ = try WebSocketConnection.makeURL(
                    host: "daemon.local", port: 4242, certFingerprint: fingerprint)
            } catch let error as WebSocketTransportError {
                #expect(error.isMissingCertificatePin)
                #expect(!error.isCertificateMismatch)
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    /// The plaintext test override is loopback-only: even when enabled it
    /// never lets a pin-less URL reach a non-loopback host.
    @Test func plaintextLoopbackOverrideNeverReachesRemoteHosts() throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }

        let loopback = try WebSocketConnection.makeURL(
            host: "127.0.0.1", port: 4242, certFingerprint: nil)
        #expect(loopback.absoluteString == "ws://127.0.0.1:4242/ws")

        #expect(throws: WebSocketTransportError.self) {
            _ = try WebSocketConnection.makeURL(
                host: "daemon.local", port: 4242, certFingerprint: nil)
        }
        #expect(throws: WebSocketTransportError.self) {
            _ = try WebSocketConnection.makeURL(
                host: "10.0.0.7", port: 4242, certFingerprint: nil)
        }
    }

    @Test func trustedPinNormalizesBlankToNil() {
        #expect(WebSocketConnection.trustedPin(nil) == nil)
        #expect(WebSocketConnection.trustedPin("") == nil)
        #expect(WebSocketConnection.trustedPin(" \n") == nil)
        #expect(WebSocketConnection.trustedPin(" aa:bb ") == "aa:bb")
    }

    @Test func pinnedWebSocketURLUsesSecureScheme() throws {
        let url = try WebSocketConnection.makeURL(
            host: "daemon.local", port: 4242, certFingerprint: "aa:bb")

        #expect(url.absoluteString == "wss://daemon.local:4242/ws")
    }

    @Test func webSocketHeadersCarryBearerAuthOnly() {
        let headers = WebSocketConnection.additionalHeaders(token: "test-token")

        #expect(headers.count == 1)
        #expect(headers[0].name == "Authorization")
        #expect(headers[0].value == "Bearer test-token")
    }

    @Test func certificateFingerprintIsColonSeparatedLowercaseSha256() {
        // SHA-256 of the empty input is a fixed, well-known vector.
        let expected = "e3:b0:c4:42:98:fc:1c:14:9a:fb:f4:c8:99:6f:b9:24:"
            + "27:ae:41:e4:64:9b:93:4c:a4:95:99:1b:78:52:b8:55"

        #expect(WebSocketConnection.fingerprint(ofCertificate: Data()) == expected)
    }

    @Test func fingerprintMatchIsCaseInsensitive() {
        #expect(WebSocketConnection.fingerprintMatches("AA:BB:CC", pinned: "aa:bb:cc"))
        #expect(WebSocketConnection.fingerprintMatches("aa:bb:cc", pinned: "AA:bb:Cc"))
        #expect(!WebSocketConnection.fingerprintMatches("aa:bb:cc", pinned: "aa:bb:cd"))
    }

    // URLSessionWebSocketTask.Message is not Equatable; extract payloads for asserting.
    private func text(of message: URLSessionWebSocketTask.Message?) -> String? {
        if case .string(let value)? = message { return value }
        return nil
    }

    private func data(of message: URLSessionWebSocketTask.Message?) -> Data? {
        if case .data(let value)? = message { return value }
        return nil
    }

    @Test func assemblerReturnsCompleteTextMessageImmediately() {
        var assembler = WebSocketConnection.MessageAssembler()

        let message = assembler.consume(
            kind: .text, data: Data("hello".utf8), isComplete: true)

        #expect(text(of: message) == "hello")
    }

    @Test func assemblerReassemblesFragmentedTextAcrossContinuations() {
        var assembler = WebSocketConnection.MessageAssembler()
        // "héllo" with the two-byte UTF-8 encoding of "é" split across
        // fragments — decoding must wait for the complete message.
        let bytes = Array("héllo".utf8)

        #expect(assembler.consume(
            kind: .text, data: Data(bytes[0..<2]), isComplete: false) == nil)
        #expect(assembler.consume(
            kind: .continuation, data: Data(bytes[2..<4]), isComplete: false) == nil)
        let message = assembler.consume(
            kind: .continuation, data: Data(bytes[4...]), isComplete: true)

        #expect(text(of: message) == "héllo")
    }

    @Test func assemblerReassemblesFragmentedBinaryMessages() {
        var assembler = WebSocketConnection.MessageAssembler()

        #expect(assembler.consume(
            kind: .binary, data: Data([0x01, 0x02]), isComplete: false) == nil)
        let message = assembler.consume(
            kind: .continuation, data: Data([0x03]), isComplete: true)

        #expect(data(of: message) == Data([0x01, 0x02, 0x03]))
    }

    @Test func assemblerDropsStrayContinuationFrames() {
        var assembler = WebSocketConnection.MessageAssembler()

        #expect(assembler.consume(
            kind: .continuation, data: Data([0xff]), isComplete: true) == nil)
        // A well-formed message afterwards is unaffected.
        let message = assembler.consume(
            kind: .text, data: Data("ok".utf8), isComplete: true)
        #expect(text(of: message) == "ok")
    }

    @Test func assemblerResetsBetweenMessages() {
        var assembler = WebSocketConnection.MessageAssembler()

        let first = assembler.consume(
            kind: .text, data: Data("first".utf8), isComplete: true)
        let second = assembler.consume(
            kind: .text, data: Data("second".utf8), isComplete: true)

        #expect(text(of: first) == "first")
        #expect(text(of: second) == "second")
    }

    @Test @MainActor func certificateMismatchErrorIncludesReceivedFingerprint() {
        let error = WebSocketTransportError.certificateMismatch(
            host: "daemon.local", fingerprint: "de:ad:be:ef")

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
        let outcome = await ConnectionManager.raceCandidates(
            ["bad.host", "good.host"]
        ) { host -> FakeRaceConnection in
            if host == "bad.host" {
                throw WebSocketTransportError.certificateMismatch(
                    host: host, fingerprint: "aa:bb")
            }
            try? await Task.sleep(for: .milliseconds(50))
            return FakeRaceConnection(host: host)
        }

        #expect(outcome.winner?.host == "good.host")
        #expect(outcome.failure == nil)
        // The race settles on the first success, so whether the loser's
        // mismatch is on the outcome or reported by the background drain
        // depends on scheduling; either way it must not be swallowed.
        let lateMismatches = await outcome.drain?.value ?? []
        #expect(outcome.mismatches + lateMismatches == [
            HostCertMismatch(host: "bad.host", fingerprint: "aa:bb")])
    }

    @Test func mismatchAfterWinnerSettledIsNotSwallowed() async {
        let outcome = await ConnectionManager.raceCandidates(
            ["good.host", "bad.host"]
        ) { host -> FakeRaceConnection in
            if host == "bad.host" {
                try? await Task.sleep(for: .milliseconds(50))
                throw WebSocketTransportError.certificateMismatch(
                    host: host, fingerprint: "cc:dd")
            }
            return FakeRaceConnection(host: host)
        }

        #expect(outcome.winner?.host == "good.host")
        // The loser's mismatch lands after the winner settled the race, so it
        // is reported by the background drain rather than the outcome itself.
        let lateMismatches = await outcome.drain?.value ?? []
        #expect(outcome.mismatches + lateMismatches == [
            HostCertMismatch(host: "bad.host", fingerprint: "cc:dd")])
    }

    @Test func allMismatchRaceFailsWithEveryHostCollected() async {
        let outcome = await ConnectionManager.raceCandidates(
            ["a.host", "b.host"]
        ) { host -> FakeRaceConnection in
            throw WebSocketTransportError.certificateMismatch(
                host: host, fingerprint: "ff:\(host)")
        }

        #expect(outcome.winner == nil)
        #expect(Set(outcome.mismatches) == Set([
            HostCertMismatch(host: "a.host", fingerprint: "ff:a.host"),
            HostCertMismatch(host: "b.host", fingerprint: "ff:b.host"),
        ]))
        let failure = outcome.failure as? WebSocketTransportError
        #expect(failure?.isCertificateMismatch == true)
        guard case .certificateMismatches(let carried)? = failure else {
            Issue.record("expected aggregate certificate error, got \(String(describing: outcome.failure))")
            return
        }
        #expect(Set(carried) == Set(outcome.mismatches))
    }

    @Test func certFailurePreferredOverGenericFailuresWhenNoWinner() async {
        let outcome = await ConnectionManager.raceCandidates(
            ["down.host", "bad.host"]
        ) { host -> FakeRaceConnection in
            if host == "bad.host" {
                try? await Task.sleep(for: .milliseconds(20))
                throw WebSocketTransportError.certificateMismatch(
                    host: host, fingerprint: "ee:ff")
            }
            throw WebSocketTransportError.failed(host: host, message: "unreachable")
        }

        #expect(outcome.winner == nil)
        #expect(outcome.mismatches == [
            HostCertMismatch(host: "bad.host", fingerprint: "ee:ff")])
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
            HostCertMismatch(host: "b", fingerprint: "f3"),
        ])

        #expect(manager.certMismatches == [
            HostCertMismatch(host: "a", fingerprint: "f2"),
            HostCertMismatch(host: "b", fingerprint: "f3"),
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
            hosts: ["h1"], port: 1234, token: "tok", certFingerprint: "pin",
            tcAddress: nil)
        let seeded = [HostCertMismatch(host: "h1", fingerprint: "f1")]
        manager.certMismatches = seeded

        manager.resetCertMismatchesIfTargetChanged(
            hosts: ["h1"], port: 1234, certFingerprint: "pin")
        #expect(manager.certMismatches == seeded)

        // Pinned targets are identified by port + pin: a drifted host list
        // (refreshHostRoutes merges daemon-reported IPs post-connect) is the
        // same daemon, so the list survives an app-driven reconnect from the
        // stored record.
        manager.resetCertMismatchesIfTargetChanged(
            hosts: ["h2"], port: 1234, certFingerprint: "pin")
        #expect(manager.certMismatches == seeded)

        manager.resetCertMismatchesIfTargetChanged(
            hosts: ["h1"], port: 1234, certFingerprint: "other-pin")
        #expect(manager.certMismatches.isEmpty)

        manager.certMismatches = seeded
        manager.resetCertMismatchesIfTargetChanged(
            hosts: ["h1"], port: 5678, certFingerprint: "pin")
        #expect(manager.certMismatches.isEmpty)
    }

    @Test @MainActor func pinlessTargetIdentityFallsBackToHostOverlap() {
        let manager = ConnectionManager.shared
        manager.updateCachedCredentials(
            hosts: ["h1", "h2"], port: 1234, token: "tok", certFingerprint: nil,
            tcAddress: nil)
        let seeded = [HostCertMismatch(host: "h1", fingerprint: "f1")]
        manager.certMismatches = seeded

        manager.resetCertMismatchesIfTargetChanged(
            hosts: ["h2", "h3"], port: 1234, certFingerprint: nil)
        #expect(manager.certMismatches == seeded)

        manager.resetCertMismatchesIfTargetChanged(
            hosts: ["h4"], port: 1234, certFingerprint: nil)
        #expect(manager.certMismatches.isEmpty)
    }

    // MARK: - Synced-registry credential adoption

    @Test @MainActor func updateCachedCredentialsReplacesReconnectFields() {
        let manager = ConnectionManager.shared
        manager.updateCachedCredentials(
            hosts: ["10.0.0.9", "mac.local"], port: 9999,
            token: "tok-rotated", certFingerprint: "ff:ee", tcAddress: nil)
        #expect(manager.hosts == ["10.0.0.9", "mac.local"])
        #expect(manager.port == 9999)
        #expect(manager.token == "tok-rotated")
        #expect(manager.certFingerprint == "ff:ee")
    }

    // MARK: - Invalid message handling

    @Test @MainActor func dispatchInvalidJsonDoesNotCrash() async {
        let manager = ConnectionManager.shared
        manager.dispatchMessage("not valid json")
        manager.dispatchMessage("")
        manager.dispatchMessage("{}")
    }

    // MARK: - Inbound frame parsing (off-main pure function)

    @Test func parseInboundFrameResponseWithResult() throws {
        let frame = ConnectionManager.parseInboundFrame("""
        {"jsonrpc":"2.0","id":7,"result":{"workspaces":[{"id":"ws-1"}]}}
        """)
        guard case .response(let id, let result)? = frame else {
            Issue.record("Expected .response, got \(String(describing: frame))")
            return
        }
        #expect(id == 7)
        let dictionary = try #require(result.value as? [String: Any])
        let workspaces = try #require(dictionary["workspaces"] as? [[String: Any]])
        #expect(workspaces.first?["id"] as? String == "ws-1")
        #expect(frame?.label == "id=7")
    }

    @Test func parseInboundFrameResponseWithoutResultFieldStillResolves() {
        let frame = ConnectionManager.parseInboundFrame("""
        {"jsonrpc":"2.0","id":8}
        """)
        guard case .response(let id, let result)? = frame else {
            Issue.record("Expected .response, got \(String(describing: frame))")
            return
        }
        #expect(id == 8)
        #expect(result.value as? [String: Any] == nil)
    }

    @Test func parseInboundFrameErrorWithDataCodeAndDataMessage() {
        let frame = ConnectionManager.parseInboundFrame("""
        {"jsonrpc":"2.0","id":9,"error":{"code":-32602,"message":"Invalid params","data":{"code":"not-found","message":"unknown agent id: gone"}}}
        """)
        guard case .error(let id, let error)? = frame else {
            Issue.record("Expected .error, got \(String(describing: frame))")
            return
        }
        #expect(id == 9)
        #expect(error.domain == "WebSocket")
        #expect(error.code == -32602)
        #expect(error.intentErrorDataCode == "not-found")
        #expect(error.isEntityNotFound)
        // error.data.message takes precedence over the top-level message.
        #expect(error.localizedDescription == "unknown agent id: gone (-32602)")
        #expect(frame?.label == "id=9")
    }

    @Test func parseInboundFrameErrorWithoutDataOmitsDataCode() {
        let frame = ConnectionManager.parseInboundFrame("""
        {"jsonrpc":"2.0","id":10,"error":{"code":-32602,"message":"unknown agent id: gone"}}
        """)
        guard case .error(let id, let error)? = frame else {
            Issue.record("Expected .error, got \(String(describing: frame))")
            return
        }
        #expect(id == 10)
        #expect(error.code == -32602)
        #expect(error.intentErrorDataCode == nil)
        #expect(!error.isEntityNotFound)
        #expect(error.localizedDescription == "unknown agent id: gone (-32602)")
    }

    @Test func parseInboundFrameErrorWithoutCodeUsesFallbackAndPlainDescription() {
        let frame = ConnectionManager.parseInboundFrame("""
        {"jsonrpc":"2.0","id":11,"error":{"message":"boom"}}
        """)
        guard case .error(_, let error)? = frame else {
            Issue.record("Expected .error, got \(String(describing: frame))")
            return
        }
        #expect(error.code == -1)
        #expect(error.localizedDescription == "boom")
    }

    @Test func parseInboundFrameNotification() throws {
        let frame = ConnectionManager.parseInboundFrame("""
        {"jsonrpc":"2.0","method":"events.event","params":{"type":"workspace:updated","data":{"id":"ws-1"}}}
        """)
        guard case .notification(let method, let params)? = frame else {
            Issue.record("Expected .notification, got \(String(describing: frame))")
            return
        }
        #expect(method == "events.event")
        let dictionary = try #require(params.value as? [String: Any])
        #expect(dictionary["type"] as? String == "workspace:updated")
        #expect(frame?.label == "method=events.event")
    }

    @Test func parseInboundFrameRejectsMalformedAndNonObjectInput() {
        #expect(ConnectionManager.parseInboundFrame("not valid json") == nil)
        #expect(ConnectionManager.parseInboundFrame("") == nil)
        #expect(ConnectionManager.parseInboundFrame("[1,2,3]") == nil)
        #expect(ConnectionManager.parseInboundFrame("\"a string\"") == nil)
        #expect(ConnectionManager.parseInboundFrame("{}") == nil)
        // A non-integer id is not a response; without a method it is dropped.
        #expect(ConnectionManager.parseInboundFrame("{\"id\":\"abc\",\"result\":1}") == nil)
    }

    @Test func parseInboundFrameRunsOffMainActor() async {
        let frame = await Task.detached {
            ConnectionManager.parseInboundFrame("{\"jsonrpc\":\"2.0\",\"id\":12,\"result\":true}")
        }.value
        guard case .response(let id, let result)? = frame else {
            Issue.record("Expected .response, got \(String(describing: frame))")
            return
        }
        #expect(id == 12)
        #expect(result.value as? Bool == true)
    }

    @Test func parseInboundFramePreDecodesChatPushOffMainActor() async throws {
        let frame = await Task.detached {
            ConnectionManager.parseInboundFrame("""
            {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"sub-chat","kind":"delta","seq":3,"delta":{"added":[{"messageId":"m-1","role":"assistant","block":{"type":"text","id":"m-1:0","text":"hi"},"streamingComplete":true}],"updated":[],"removedIds":[]}}}
            """)
        }.value
        guard case .subscriptionPush(let push)? = frame else {
            Issue.record("Expected .subscriptionPush, got \(String(describing: frame))")
            return
        }
        #expect(push.subscriptionId == "sub-chat")
        #expect(push.kind == .delta)
        #expect(push.seq == 3)
        let chatBlocks = try #require(push.delta?.chatBlocks)
        #expect(chatBlocks.count == 1)
        #expect(chatBlocks.first?.messageId == "m-1")
        #expect(chatBlocks.first?.block.resolvedText == "hi")
        #expect(chatBlocks.first?.streamingComplete == true)
        #expect(frame?.label == "method=subscription.push")
    }

    @Test func parseInboundFrameChatSnapshotPushRunsOffMainActor() async throws {
        let frame = await Task.detached {
            ConnectionManager.parseInboundFrame("""
            {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"sub-chat","kind":"snapshot","seq":0,"snapshot":{"agentId":"a","truncated":false,"totalMessages":1,"messages":[{"id":"m-1","role":"user","timestamp":"t","contentBlocks":[{"type":"text","id":"m-1:0","text":"Run the tests"}]}]}}}
            """)
        }.value
        guard case .subscriptionPush(let push)? = frame else {
            Issue.record("Expected .subscriptionPush, got \(String(describing: frame))")
            return
        }
        let messages = try #require(push.snapshotMessages)
        #expect(messages.map(\.id) == ["m-1"])
        #expect(messages.first?.contentBlocks?.first?.resolvedText == "Run the tests")
        #expect(push.snapshotMeta?["agentId"] as? String == "a")
    }

    @Test func slowFrameLogLineIncludesMainActorWaitInThresholdCheck() {
        let threshold = 0.05
        // Fast parse and dispatch, but the frame sat behind a busy main thread.
        let waited = ConnectionManager.slowFrameLogLine(
            label: "method=subscription.push", byteCount: 512,
            parseElapsed: 0.002, waitElapsed: 0.4, dispatchElapsed: 0.001, threshold: threshold)
        #expect(waited == "[ConnectionManager] slow frame method=subscription.push bytes=512 parse=2ms wait=400ms dispatch=1ms")

        #expect(ConnectionManager.slowFrameLogLine(
            label: "id=1", byteCount: 10,
            parseElapsed: 0.2, waitElapsed: 0, dispatchElapsed: 0, threshold: threshold) != nil)
        #expect(ConnectionManager.slowFrameLogLine(
            label: "id=1", byteCount: 10,
            parseElapsed: 0, waitElapsed: 0, dispatchElapsed: 0.2, threshold: threshold) != nil)
        #expect(ConnectionManager.slowFrameLogLine(
            label: "id=1", byteCount: 10,
            parseElapsed: 0.01, waitElapsed: 0.01, dispatchElapsed: 0.01, threshold: threshold) == nil)
    }

    @Test func parseInboundFrameMalformedPushStaysNotification() throws {
        let frame = ConnectionManager.parseInboundFrame("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"sub-1","kind":"snapshot","seq":0}}
        """)
        guard case .notification(let method, let params)? = frame else {
            Issue.record("Expected .notification, got \(String(describing: frame))")
            return
        }
        #expect(method == "subscription.push")
        let dictionary = try #require(params.value as? [String: Any])
        #expect(dictionary["subscriptionId"] as? String == "sub-1")
    }

    // MARK: - Subscription Push Routing

    @Test @MainActor func registerSubscriptionHandlerStoresHandler() async {
        let manager = ConnectionManager.shared
        var receivedPush: SubscriptionPush?

        manager.registerSubscriptionHandler(id: "test-sub-1") { push in
            receivedPush = push
        }

        // Verify the push is routed correctly
        let pushMessage = """
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"test-sub-1","kind":"snapshot","seq":0,"snapshot":[]}}
        """
        manager.dispatchMessage(pushMessage)

        #expect(receivedPush != nil)
        #expect(receivedPush?.subscriptionId == "test-sub-1")
        #expect(receivedPush?.kind == .snapshot)

        // Clean up
        manager.unregisterSubscriptionHandler(id: "test-sub-1")
    }

    @Test @MainActor func pushForUnknownSubscriptionIsDropped() async {
        let manager = ConnectionManager.shared

        // No handler registered for this id
        let pushMessage = """
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"unknown-sub","kind":"snapshot","seq":0,"snapshot":[]}}
        """
        // Should not crash, just drop and log
        manager.dispatchMessage(pushMessage)
    }

    @Test @MainActor func unregisterRemovesHandler() async {
        let manager = ConnectionManager.shared
        var receivedCount = 0

        manager.registerSubscriptionHandler(id: "test-sub-2") { _ in
            receivedCount += 1
        }

        let pushMessage = """
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"test-sub-2","kind":"snapshot","seq":0,"snapshot":[]}}
        """

        // First push should be received
        manager.dispatchMessage(pushMessage)
        #expect(receivedCount == 1)

        // Unregister
        manager.unregisterSubscriptionHandler(id: "test-sub-2")

        // Second push should be dropped
        manager.dispatchMessage(pushMessage)
        #expect(receivedCount == 1) // Still 1, not incremented
    }

    // Subscriptions are per-connection (PROTOCOL §6.1, monorepo#2213): disconnect
    // must drop all registered subscription handlers, buffered unrouted pushes, and
    // unregister tombstones — ids can be reused after a daemon restart, so stale
    // prior-connection buffer/tombstone state must not leak into the next connection.
    @Test @MainActor func disconnectClearsSubscriptionHandlers() async {
        let manager = ConnectionManager.shared
        var receivedCount = 0

        manager.registerSubscriptionHandler(id: "disc-sub-1") { _ in
            receivedCount += 1
        }
        #expect(manager.subscriptionHandlerCount >= 1)

        // Seed per-connection buffer + tombstone state: an unrouted push for an
        // unregistered id gets buffered, and unregistering lays a tombstone.
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"disc-sub-buffered","kind":"snapshot","seq":0,"snapshot":[]}}
        """)
        manager.unregisterSubscriptionHandler(id: "disc-sub-tombstoned")
        #expect(manager.hasBufferedSubscriptionPush(for: "disc-sub-buffered"))
        #expect(manager.hasRecentlyUnregisteredSubscription(id: "disc-sub-tombstoned"))

        manager.disconnect()
        #expect(manager.subscriptionHandlerCount == 0)
        #expect(!manager.hasBufferedSubscriptionPush(for: "disc-sub-buffered"))
        #expect(!manager.hasRecentlyUnregisteredSubscription(id: "disc-sub-tombstoned"))

        // A push for the cleared id no longer reaches the handler
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"disc-sub-1","kind":"snapshot","seq":0,"snapshot":[]}}
        """)
        #expect(receivedCount == 0)

        // Clean up: the unrouted push above was buffered for replay; drop it
        manager.unregisterSubscriptionHandler(id: "disc-sub-1")
    }

    @Test @MainActor func twoHandlersOnlyReceiveTheirOwnPushes() async {
        let manager = ConnectionManager.shared
        var receivedPush1: SubscriptionPush?
        var receivedPush2: SubscriptionPush?

        manager.registerSubscriptionHandler(id: "test-sub-a") { push in
            receivedPush1 = push
        }

        manager.registerSubscriptionHandler(id: "test-sub-b") { push in
            receivedPush2 = push
        }

        // Send push for subscription A
        let pushA = """
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"test-sub-a","kind":"snapshot","seq":1,"snapshot":[]}}
        """
        manager.dispatchMessage(pushA)

        #expect(receivedPush1?.subscriptionId == "test-sub-a")
        #expect(receivedPush1?.seq == 1)
        #expect(receivedPush2 == nil) // Handler B should not receive A's push

        // Reset and send push for subscription B
        receivedPush1 = nil
        receivedPush2 = nil

        let pushB = """
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"test-sub-b","kind":"snapshot","seq":2,"snapshot":[]}}
        """
        manager.dispatchMessage(pushB)

        #expect(receivedPush1 == nil) // Handler A should not receive B's push
        #expect(receivedPush2?.subscriptionId == "test-sub-b")
        #expect(receivedPush2?.seq == 2)

        // Clean up
        manager.unregisterSubscriptionHandler(id: "test-sub-a")
        manager.unregisterSubscriptionHandler(id: "test-sub-b")
    }

    @Test @MainActor func reregisterSameIdReplacesHandler() async {
        let manager = ConnectionManager.shared
        var firstHandlerCalled = false
        var secondHandlerCalled = false

        manager.registerSubscriptionHandler(id: "test-sub-3") { _ in
            firstHandlerCalled = true
        }

        // Re-register with new handler
        manager.registerSubscriptionHandler(id: "test-sub-3") { _ in
            secondHandlerCalled = true
        }

        let pushMessage = """
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"test-sub-3","kind":"snapshot","seq":0,"snapshot":[]}}
        """
        manager.dispatchMessage(pushMessage)

        #expect(!firstHandlerCalled) // Old handler should not be called
        #expect(secondHandlerCalled) // New handler should be called

        // Clean up
        manager.unregisterSubscriptionHandler(id: "test-sub-3")
    }

    @Test @MainActor func subscriptionPushDoesNotReachLegacyEventHandlers() async {
        let manager = ConnectionManager.shared
        var legacyHandlerReceivedSubscriptionPush = false
        var routerHandlerReceivedPush = false

        let handlerId = manager.onEvent { method, _ in
            if method == "subscription.push" {
                legacyHandlerReceivedSubscriptionPush = true
            }
        }

        // Register a subscription handler to consume the push
        manager.registerSubscriptionHandler(id: "test-sub-4") { _ in
            routerHandlerReceivedPush = true
        }

        let pushMessage = """
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"test-sub-4","kind":"snapshot","seq":0,"snapshot":[]}}
        """
        manager.dispatchMessage(pushMessage)

        // Router is the SINGLE source of subscription.push dispatch.
        // Legacy eventHandlers must NOT receive subscription.push.
        #expect(routerHandlerReceivedPush)
        #expect(!legacyHandlerReceivedSubscriptionPush)

        // Clean up
        manager.removeEventHandler(id: handlerId)
        manager.unregisterSubscriptionHandler(id: "test-sub-4")
    }

    @Test @MainActor func malformedSubscriptionPushIsDropped() async {
        let manager = ConnectionManager.shared
        var legacyHandlerReceivedSubscriptionPush = false
        var routerHandlerCalled = false

        let handlerId = manager.onEvent { method, _ in
            if method == "subscription.push" {
                legacyHandlerReceivedSubscriptionPush = true
            }
        }

        manager.registerSubscriptionHandler(id: "test-sub-5") { _ in
            routerHandlerCalled = true
        }

        // Missing required fields (no "seq" or "kind")
        let malformedPushMessage = """
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"test-sub-5"}}
        """
        manager.dispatchMessage(malformedPushMessage)

        // Malformed push should be dropped entirely: no router dispatch, no legacy broadcast
        #expect(!routerHandlerCalled)
        #expect(!legacyHandlerReceivedSubscriptionPush)

        // Clean up
        manager.removeEventHandler(id: handlerId)
        manager.unregisterSubscriptionHandler(id: "test-sub-5")
    }

    @Test @MainActor func unregisteredSubscriptionIdIsDropped() async {
        let manager = ConnectionManager.shared
        var legacyHandlerReceivedSubscriptionPush = false

        let handlerId = manager.onEvent { method, _ in
            if method == "subscription.push" {
                legacyHandlerReceivedSubscriptionPush = true
            }
        }

        // Do NOT register a handler for "test-sub-6"
        let pushMessage = """
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"test-sub-6","kind":"snapshot","seq":0,"snapshot":[]}}
        """
        manager.dispatchMessage(pushMessage)

        // Unregistered push should not be dispatched to legacy handlers (it is buffered
        // for potential replay, never broadcast)
        #expect(!legacyHandlerReceivedSubscriptionPush)

        // Clean up
        manager.removeEventHandler(id: handlerId)
        manager.unregisterSubscriptionHandler(id: "test-sub-6")
    }

    // MARK: - Unrouted push buffering (dropped seq-0 snapshot race)

    @Test @MainActor func bufferedPushesReplayedInOrderOnRegistration() async {
        let manager = ConnectionManager.shared
        var received: [(kind: SubscriptionPush.Kind, seq: Int)] = []

        // Snapshot + deltas arrive BEFORE any handler is registered (the race)
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-1","kind":"snapshot","seq":0,"snapshot":{"agentId":"a1","messages":[]}}}
        """)
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-1","kind":"delta","seq":1,"delta":{"added":[],"updated":[],"removedIds":[]}}}
        """)
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-1","kind":"delta","seq":2,"delta":{"added":[],"updated":[],"removedIds":[]}}}
        """)

        manager.registerSubscriptionHandler(id: "buf-sub-1") { push in
            received.append((push.kind, push.seq))
        }

        // Replayed synchronously on registration, in arrival order
        #expect(received.count == 3)
        #expect(received[0].kind == .snapshot && received[0].seq == 0)
        #expect(received[1].kind == .delta && received[1].seq == 1)
        #expect(received[2].kind == .delta && received[2].seq == 2)
        // Buffer cleared after replay
        #expect(!manager.hasBufferedSubscriptionPush(for: "buf-sub-1"))

        // Clean up
        manager.unregisterSubscriptionHandler(id: "buf-sub-1")
    }

    @Test @MainActor func bufferEvictionRespectsBounds() async {
        let manager = ConnectionManager.shared
        manager.disconnect()

        let limit = ConnectionSubscriptionRouter.defaultBufferLimit
        let total = limit + 6
        for seq in 0..<total {
            manager.dispatchMessage("""
            {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-evict","kind":"delta","seq":\(seq),"delta":{"added":[],"updated":[],"removedIds":[]}}}
            """)
        }
        #expect(manager.bufferedSubscriptionPushCount == limit)

        var receivedSeqs: [Int] = []
        manager.registerSubscriptionHandler(id: "buf-sub-evict") { push in
            receivedSeqs.append(push.seq)
        }

        // Oldest frames evicted; the most recent `limit` frames replayed in order
        #expect(receivedSeqs == Array((total - limit)..<total))

        // Clean up
        manager.unregisterSubscriptionHandler(id: "buf-sub-evict")
    }

    @Test @MainActor func bufferTTLExpiresOldPushes() async {
        var currentDate = Date()
        let router = ConnectionSubscriptionRouter(now: { currentDate })
        let delta: [String: Any] = ["added": [], "updated": [], "removedIds": []]

        _ = router.route(method: "subscription.push", params: [
            "subscriptionId": "buf-sub-ttl", "kind": "delta", "seq": 1, "delta": delta
        ])
        currentDate.addTimeInterval(ConnectionSubscriptionRouter.defaultBufferTTL + 1)
        _ = router.route(method: "subscription.push", params: [
            "subscriptionId": "buf-sub-ttl", "kind": "delta", "seq": 2, "delta": delta
        ])

        var receivedSeqs: [Int] = []
        router.register(id: "buf-sub-ttl") { push in
            receivedSeqs.append(push.seq)
        }

        // Only the fresh push replays; the expired one is pruned
        #expect(receivedSeqs == [2])

        router.unregister(id: "buf-sub-ttl")
    }

    @Test @MainActor func noDoubleDeliveryWhenHandlerRegisteredMidStream() async {
        let manager = ConnectionManager.shared
        var receivedSeqs: [Int] = []

        // seq 0 arrives pre-registration → buffered
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-mid","kind":"snapshot","seq":0,"snapshot":{"agentId":"a1","messages":[]}}}
        """)

        manager.registerSubscriptionHandler(id: "buf-sub-mid") { push in
            receivedSeqs.append(push.seq)
        }
        // Replay delivered seq 0 exactly once
        #expect(receivedSeqs == [0])

        // seq 1 arrives post-registration → routed live, never buffered
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-mid","kind":"delta","seq":1,"delta":{"added":[],"updated":[],"removedIds":[]}}}
        """)
        #expect(receivedSeqs == [0, 1])
        #expect(!manager.hasBufferedSubscriptionPush(for: "buf-sub-mid"))

        // Clean up
        manager.unregisterSubscriptionHandler(id: "buf-sub-mid")
    }

    @Test @MainActor func unregisterDropsBufferedPushes() async {
        let manager = ConnectionManager.shared

        // Push buffered for a subscription that then gets unregistered (e.g. resnapshot)
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-unreg","kind":"snapshot","seq":0,"snapshot":{"agentId":"a1","messages":[]}}}
        """)
        manager.unregisterSubscriptionHandler(id: "buf-sub-unreg")

        var receivedCount = 0
        manager.registerSubscriptionHandler(id: "buf-sub-unreg") { _ in
            receivedCount += 1
        }
        // Buffered push for the dead subscription must not replay
        #expect(receivedCount == 0)

        // Clean up
        manager.unregisterSubscriptionHandler(id: "buf-sub-unreg")
    }

    @Test @MainActor func stragglerPushesAfterUnregisterAreNotBuffered() async {
        let manager = ConnectionManager.shared

        manager.registerSubscriptionHandler(id: "buf-sub-dead") { _ in }
        manager.unregisterSubscriptionHandler(id: "buf-sub-dead")

        // Straggler pushes for the dead id (unsubscribe still in flight on the daemon)
        // must be dropped, not buffered — they can never replay and would only add
        // eviction pressure on the shared buffer
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-dead","kind":"delta","seq":7,"delta":{"added":[],"updated":[],"removedIds":[]}}}
        """)
        #expect(!manager.hasBufferedSubscriptionPush(for: "buf-sub-dead"))

        // A brand-new subscriptionId is unaffected by the tombstone
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-fresh","kind":"snapshot","seq":0,"snapshot":{"agentId":"a1","messages":[]}}}
        """)
        var receivedSeqs: [Int] = []
        manager.registerSubscriptionHandler(id: "buf-sub-fresh") { push in
            receivedSeqs.append(push.seq)
        }
        #expect(receivedSeqs == [0])

        // Clean up
        manager.unregisterSubscriptionHandler(id: "buf-sub-fresh")
    }

    @Test @MainActor func reusedIdRevivedByFreshSnapshotAfterUnregister() async {
        let manager = ConnectionManager.shared

        manager.registerSubscriptionHandler(id: "buf-sub-reused") { _ in }
        manager.unregisterSubscriptionHandler(id: "buf-sub-reused")

        // A seq-0 snapshot for the tombstoned id means the daemon reused it for a
        // brand-new subscription (ids reset on daemon restart) — it must be buffered
        // and replayed, not dropped
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-reused","kind":"snapshot","seq":0,"snapshot":{"agentId":"a1","messages":[]}}}
        """)
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-reused","kind":"delta","seq":1,"delta":{"added":[],"updated":[],"removedIds":[]}}}
        """)

        var receivedSeqs: [Int] = []
        manager.registerSubscriptionHandler(id: "buf-sub-reused") { push in
            receivedSeqs.append(push.seq)
        }
        #expect(receivedSeqs == [0, 1])

        // Clean up
        manager.unregisterSubscriptionHandler(id: "buf-sub-reused")
    }

    @Test @MainActor func collectionChannelPushesUnaffectedByBuffering() async {
        let manager = ConnectionManager.shared
        var received: [(kind: SubscriptionPush.Kind, seq: Int, count: Int)] = []

        // Registered-first (normal collection-channel flow): pushes route live
        manager.registerSubscriptionHandler(id: "col-sub-1") { push in
            received.append((push.kind, push.seq, push.snapshot?.count ?? 0))
        }
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"col-sub-1","kind":"snapshot","seq":0,"snapshot":[{"id":"note-1"},{"id":"note-2"}]}}
        """)
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"col-sub-1","kind":"delta","seq":1,"delta":{"added":[],"updated":[{"id":"note-1"}],"removedIds":[]}}}
        """)
        #expect(received.count == 2)
        #expect(received[0].kind == .snapshot && received[0].seq == 0 && received[0].count == 2)
        #expect(received[1].kind == .delta && received[1].seq == 1)
        #expect(!manager.hasBufferedSubscriptionPush(for: "col-sub-1"))

        // Array-shaped (collection) snapshot arriving pre-registration replays intact
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"col-sub-2","kind":"snapshot","seq":0,"snapshot":[{"id":"task-1"}]}}
        """)
        var replayedSnapshot: [[String: Any]]?
        manager.registerSubscriptionHandler(id: "col-sub-2") { push in
            replayedSnapshot = push.snapshot
        }
        #expect(replayedSnapshot?.count == 1)
        #expect(replayedSnapshot?.first?["id"] as? String == "task-1")

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
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-chat-race","kind":"snapshot","seq":0,"snapshot":{"agentId":"agent-1","messages":[{"id":"msg-1","role":"user","contentBlocks":[{"type":"text","id":"msg-1:0","text":"Hello"}],"timestamp":"2026-07-21T01:00:00.000Z"}]}}}
        """)
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-chat-race","kind":"delta","seq":1,"delta":{"added":[{"agentId":"agent-1","messageId":"msg-2","role":"assistant","block":{"type":"text","id":"msg-2:0","text":"Working"}}],"updated":[],"removedIds":[]}}}
        """)

        // The store registers its handler (as subscribeLiveChat does after the
        // subscribe response resumes) → buffered pushes replay and apply
        manager.registerSubscriptionHandler(id: "buf-chat-race") { [weak store] push in
            store?.handleChatSubscriptionPush(push)
        }

        #expect(store.messages.count == 2)
        #expect(store.messages[0].id == "msg-1")
        #expect(store.messages[1].id == "msg-2")
        #expect(store.messages[1].contentBlocks?.first?.resolvedText == "Working")
        #expect(store.isStreaming == true)

        // The channel is seeded correctly: the next live delta continues the
        // sequence without a gap (no resnapshot wiped the seeded state)
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-chat-race","kind":"delta","seq":2,"delta":{"added":[],"updated":[{"agentId":"agent-1","messageId":"msg-2","role":"assistant","block":{"type":"text","id":"msg-2:0","text":"Working on it."}}],"removedIds":[]}}}
        """)
        #expect(store.messages[1].contentBlocks?.first?.resolvedText == "Working on it.")

        // Clean up
        manager.unregisterSubscriptionHandler(id: "buf-chat-race")
    }

    // MARK: - Host route merge (post-connect refresh)

    @Test @MainActor func mergeHostsAppendsNewReportedIps() {
        let merged = ConnectionManager.mergeHosts(
            existing: ["192.168.1.10"],
            reported: ["192.168.1.10", "10.0.0.5", "172.16.0.2"])
        #expect(merged == ["192.168.1.10", "10.0.0.5", "172.16.0.2"])
    }

    @Test @MainActor func mergeHostsKeepsExistingOrderFirstAndNeverDrops() {
        // The user-entered host is not in the daemon-reported list (e.g. a
        // hostname or NAT address) — it must stay, and stay first.
        let merged = ConnectionManager.mergeHosts(
            existing: ["daemon.local", "10.0.0.5"],
            reported: ["10.0.0.5", "192.168.1.10"])
        #expect(merged == ["daemon.local", "10.0.0.5", "192.168.1.10"])
    }

    @Test @MainActor func mergeHostsDedupesAndSkipsEmptyReportedEntries() {
        let merged = ConnectionManager.mergeHosts(
            existing: ["a"],
            reported: ["b", "b", "", "  ", "a", " c "])
        #expect(merged == ["a", "b", "c"])
    }

    @Test @MainActor func mergeHostsWithNoReportedIpsIsUnchanged() {
        #expect(ConnectionManager.mergeHosts(existing: ["a", "b"], reported: []) == ["a", "b"])
    }

    @Test @MainActor func persistedMergeKeepsStoredHostsSessionDidNotConnectWith() {
        // Reviewer scenario: the stored record holds a NAT hostname the current
        // session didn't connect with. The persisted list is the stored hosts
        // merged with the session's merge result — the NAT hostname survives.
        let storedHosts = ["nat.example.com", "192.168.1.10"]
        let sessionMerged = ConnectionManager.mergeHosts(
            existing: ["192.168.1.10"],
            reported: ["192.168.1.10", "10.0.0.5"])
        #expect(sessionMerged == ["192.168.1.10", "10.0.0.5"])

        let persisted = ConnectionManager.mergeHosts(existing: storedHosts, reported: sessionMerged)
        #expect(persisted == ["nat.example.com", "192.168.1.10", "10.0.0.5"])
    }

    // MARK: - localIps parsing (system.status)

    @Test @MainActor func localIpsParsedFromSystemStatusResult() {
        let result: [String: Any] = [
            "version": "1.2.3",
            "hostname": "mac.local",
            "localIps": ["192.168.1.10", "10.0.0.5"],
        ]
        #expect(ConnectionManager.localIps(fromSystemStatus: result) == ["192.168.1.10", "10.0.0.5"])
    }

    @Test @MainActor func localIpsNilWhenFieldAbsentOnOlderDaemon() {
        let result: [String: Any] = ["version": "1.0.0"]
        #expect(ConnectionManager.localIps(fromSystemStatus: result) == nil)
    }

    @Test @MainActor func localIpsNilWhenMalformed() {
        #expect(ConnectionManager.localIps(fromSystemStatus: ["localIps": "not-an-array"]) == nil)
        #expect(ConnectionManager.localIps(fromSystemStatus: ["localIps": [1, 2]]) == nil)
        #expect(ConnectionManager.localIps(fromSystemStatus: "not-a-dict") == nil)
        #expect(ConnectionManager.localIps(fromSystemStatus: NSNull()) == nil)
    }

    // MARK: - tcAddress parsing (system.status)

    @Test @MainActor func tcAddressParsedFromSystemStatusResult() {
        let result: [String: Any] = [
            "version": "1.2.3",
            "tcAddress": "tc-abcdef123456",
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
            hosts: ["h1"], port: 1, token: "t", certFingerprint: nil,
            tcAddress: "tc-tunnel-token")
        #expect(manager.tcAddress == "tc-tunnel-token")
        manager.updateCachedCredentials(
            hosts: ["h1"], port: 1, token: "t", certFingerprint: nil,
            tcAddress: nil)
        #expect(manager.tcAddress == nil)
    }

    // MARK: - Tunnel race candidate

    private nonisolated final class FakeTunnelSession: TunnelSession, @unchecked Sendable {
        let localPort: Int
        let closed = OSAllocatedUnfairLock(initialState: false)
        init(localPort: Int) { self.localPort = localPort }
        func close() async { closed.withLock { $0 = true } }
        var isClosed: Bool { closed.withLock { $0 } }
    }

    private nonisolated struct FakeTunnelDialer: TunnelDialing {
        let result: Result<FakeTunnelSession, WebSocketTransportError>
        func open(tcAddress: String, remotePort: Int) async throws -> any TunnelSession {
            try result.get()
        }
    }

    /// Platforms without a TailcatKit build (visionOS) default to
    /// `UnavailableTunnelDialer`: a tunnel candidate fails with the clear
    /// unavailable error, labeled to the tunnel route, instead of crashing.
    @Test func unavailableTunnelDialerFailsWithClearError() async {
        do {
            _ = try await ConnectionManager.connectViaTunnel(
                dialer: UnavailableTunnelDialer(), tcAddress: "tc-x", remotePort: 5181,
                token: "t", certFingerprint: nil)
            Issue.record("expected connectViaTunnel to throw")
        } catch let error as WebSocketTransportError {
            guard case .failed(let host, let message) = error else {
                Issue.record("unexpected transport error: \(error)")
                return
            }
            #expect(host == ConnectionManager.tunnelCandidateLabel)
            #expect(message == UnavailableTunnelDialer.unavailableMessage)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    /// A failed tunnel dial surfaces as a candidate failure with the tunnel
    /// label (not a raw loopback host).
    @Test func tunnelDialFailurePropagates() async {
        let dialer = FakeTunnelDialer(
            result: .failure(.failed(
                host: ConnectionManager.tunnelCandidateLabel, message: "no derp")))
        await #expect(throws: WebSocketTransportError.self) {
            _ = try await ConnectionManager.connectViaTunnel(
                dialer: dialer, tcAddress: "tc-x", remotePort: 5181,
                token: "t", certFingerprint: nil)
        }
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
                dialer: dialer, tcAddress: "tc-x", remotePort: 5181,
                token: "t", certFingerprint: "aa:bb")
        }
        #expect(tunnel.isClosed)
    }

    /// ios#251: a pin-less tunnel candidate is refused before its WSS
    /// handshake, the tunnel is released, and the error is labeled to the
    /// tunnel route like every other tunnel failure.
    @Test func tunnelRefusesPinlessSocketAndCloses() async {
        let tunnel = FakeTunnelSession(localPort: 1)
        let dialer = FakeTunnelDialer(result: .success(tunnel))
        do {
            _ = try await ConnectionManager.connectViaTunnel(
                dialer: dialer, tcAddress: "tc-x", remotePort: 5181,
                token: "t", certFingerprint: nil)
            Issue.record("expected connectViaTunnel to refuse a pin-less record")
        } catch let error as WebSocketTransportError {
            guard case .missingCertificatePin(let host) = error else {
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
    private nonisolated struct FakeTunnelRaceConnection: HostRacingConnection {
        let host: String
        let tunnel: FakeTunnelSession?

        func disconnect() async {
            await tunnel?.close()
        }
    }

    /// When a direct host wins the race, the LOSING tunnel candidate's session
    /// must be closed by `raceCandidates` loser cleanup (no leaked tunnel).
    @Test func losingTunnelCandidateSessionClosedWhenDirectHostWins() async {
        let tunnel = FakeTunnelSession(localPort: 1)
        let outcome = await ConnectionManager.raceCandidates(
            ["direct.host", ConnectionManager.tunnelCandidateLabel]
        ) { host -> FakeTunnelRaceConnection in
            if host == ConnectionManager.tunnelCandidateLabel {
                try? await Task.sleep(for: .milliseconds(50))
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
    @Test func raceSettlesOnWinnerWithoutWaitingForUncancellableLoser() async {
        let loserTunnel = FakeTunnelSession(localPort: 1)
        let start = ContinuousClock.now
        let outcome = await ConnectionManager.raceCandidates(
            ["direct.host", ConnectionManager.tunnelCandidateLabel]
        ) { host -> FakeTunnelRaceConnection in
            if host == ConnectionManager.tunnelCandidateLabel {
                // Sleeping in a detached task and awaiting its value is not
                // interrupted by the candidate task's cancellation.
                _ = await Task.detached {
                    try? await Task.sleep(for: .seconds(2))
                }.value
                return FakeTunnelRaceConnection(host: host, tunnel: loserTunnel)
            }
            return FakeTunnelRaceConnection(host: host, tunnel: nil)
        }
        let elapsed = ContinuousClock.now - start

        #expect(outcome.winner?.host == "direct.host")
        #expect(outcome.failure == nil)
        #expect(elapsed < .seconds(1), "race waited on the loser: \(elapsed)")
        // The loser is still in flight; cleanup happens off the critical path.
        #expect(!loserTunnel.isClosed)
        _ = await outcome.drain?.value
        #expect(loserTunnel.isClosed)
    }

    // MARK: - Pairing over a live connection (monorepo#4185)

    /// Loopback plain-WS listener with a minimal JSON-RPC responder: any
    /// request carrying an `id` gets an empty-object result; notifications
    /// are ignored. Lets `connect()` tests establish real sockets and prove
    /// a connection still serves round-trips. Nonisolated for the same
    /// reason as ManualTokenEntryViewTests' TLS listener: the handlers run
    /// on the listener queue and must not inherit MainActor isolation.
    private nonisolated final class LoopbackWebSocketServer: @unchecked Sendable {
        /// How the server answers websocket pings. `.automatic` lets the
        /// framework reply; `.replied` and `.withheld` deliver pings to the
        /// server loop (counted in `pingsReceived`), which pongs back or
        /// stays silent respectively — the heartbeat tests' seam.
        enum PongPolicy {
            case automatic, replied, withheld
        }

        private struct State {
            var accepted: [NWConnection] = []
            // Connections held back by a gated server: accepted but not
            // started, so the client's WS handshake stays pending until
            // `open()` releases them. Lets tests control which of two
            // racing connect() calls completes first.
            var pendingStart: [NWConnection] = []
            var isOpen: Bool
            var acceptedTotal = 0
            var pingsReceived = 0
        }

        private let listener: NWListener
        private let queue = DispatchQueue(label: "ConnectionManagerTests.ws-server")
        private let pongs: PongPolicy
        // Retain accepted connections for the listener's lifetime (an
        // unreferenced NWConnection deallocates and drops the socket).
        private let state: OSAllocatedUnfairLock<State>

        var port: Int { Int(listener.port?.rawValue ?? 0) }
        var pingsReceived: Int { state.withLock { $0.pingsReceived } }

        /// Sockets the listener has accepted so far (including ones cancelled
        /// since): non-zero proves a client reached this plaintext server.
        var acceptedCount: Int { state.withLock { $0.acceptedTotal } }

        private init(listener: NWListener, gated: Bool, pongs: PongPolicy) {
            self.listener = listener
            self.pongs = pongs
            self.state = OSAllocatedUnfairLock(initialState: State(isOpen: !gated))
        }

        static func start(
            gated: Bool = false, pongs: PongPolicy = .automatic
        ) async throws -> LoopbackWebSocketServer {
            let parameters = NWParameters.tcp
            let wsOptions = NWProtocolWebSocket.Options()
            wsOptions.autoReplyPing = pongs == .automatic
            parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
            let server = LoopbackWebSocketServer(
                listener: try NWListener(using: parameters, on: .any), gated: gated, pongs: pongs)
            server.listener.newConnectionHandler = { [weak server] connection in
                guard let server else { return }
                let startNow = server.state.withLock { state in
                    state.accepted.append(connection)
                    state.acceptedTotal += 1
                    if !state.isOpen { state.pendingStart.append(connection) }
                    return state.isOpen
                }
                guard startNow else { return }
                server.receiveNext(on: connection)
                connection.start(queue: server.queue)
            }
            let resumed = OSAllocatedUnfairLock(initialState: false)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                server.listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready, .failed, .cancelled:
                        let alreadyResumed = resumed.withLock { (done: inout Bool) -> Bool in
                            let was = done
                            done = true
                            return was
                        }
                        if !alreadyResumed { continuation.resume() }
                    default:
                        break
                    }
                }
                server.listener.start(queue: server.queue)
            }
            return server
        }

        /// Releases a gated server: starts every held-back connection so
        /// their pending WS handshakes complete, and starts future ones
        /// immediately.
        func open() {
            let held = state.withLock { state in
                state.isOpen = true
                let pending = state.pendingStart
                state.pendingStart.removeAll()
                return pending
            }
            for connection in held {
                receiveNext(on: connection)
                connection.start(queue: queue)
            }
        }

        func stop() {
            listener.cancel()
            state.withLock { state in
                for connection in state.accepted { connection.cancel() }
                state.accepted.removeAll()
                state.pendingStart.removeAll()
            }
        }

        /// Drops every accepted client socket but keeps listening, so the
        /// client's automatic reconnect can re-establish against this server.
        func dropClients() {
            let dropped = state.withLock { state in
                defer { state.accepted.removeAll() }
                return state.accepted
            }
            for connection in dropped { connection.cancel() }
        }

        private func receiveNext(on connection: NWConnection) {
            connection.receiveMessage { [weak self] data, context, _, error in
                guard let self, error == nil else { return }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata
                if metadata?.opcode == .ping {
                    self.state.withLock { $0.pingsReceived += 1 }
                    if self.pongs == .replied {
                        let pong = NWProtocolWebSocket.Metadata(opcode: .pong)
                        let pongContext = NWConnection.ContentContext(
                            identifier: "pong", metadata: [pong])
                        connection.send(
                            content: data, contentContext: pongContext,
                            isComplete: true, completion: .idempotent)
                    }
                } else if let data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = json["id"] {
                    let response: [String: Any] = [
                        "jsonrpc": "2.0", "id": id, "result": [String: Any](),
                    ]
                    if let payload = try? JSONSerialization.data(withJSONObject: response) {
                        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
                        let context = NWConnection.ContentContext(
                            identifier: "response", metadata: [metadata])
                        connection.send(
                            content: payload, contentContext: context,
                            completion: .idempotent)
                    }
                }
                self.receiveNext(on: connection)
            }
        }
    }

    /// A loopback port with nothing listening on it, so connections are
    /// refused fast and deterministically.
    private static func unusedLoopbackPort() async throws -> Int {
        let server = try await LoopbackWebSocketServer.start()
        let port = server.port
        server.stop()
        return port
    }

    /// The socket tests below dial the plaintext `LoopbackWebSocketServer`
    /// without a pin, so they opt into the loopback-only override explicitly
    /// and restore the fail-closed default on exit (the suite is serialized).
    private static func enablePlaintextLoopback() -> Bool {
        WebSocketConnection.allowsPlaintextLoopbackForTesting.withLock { state in
            let was = state
            state = true
            return was
        }
    }

    private static func restorePlaintextLoopback(_ previous: Bool) {
        WebSocketConnection.allowsPlaintextLoopbackForTesting.withLock { $0 = previous }
    }

    /// The enable/restore pair is registered before any throwing setup, so a
    /// failed server start cannot leak the plaintext override into later tests.
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

    /// ios#251 (RED on origin/main): a saved record without a certificate
    /// pin must fail closed — `connect()` refuses before any socket opens,
    /// so the bearer token is never sent over plain ws://. The plaintext
    /// server listening on the target port proves no connection reached it.
    @Test @MainActor func pinlessConnectNeverOpensPlaintextSocket() async throws {
        let manager = ConnectionManager.shared
        let server = try await LoopbackWebSocketServer.start()
        defer {
            manager.disconnect()
            server.stop()
        }
        #expect(!WebSocketConnection.plaintextLoopbackOverrideActive)
        let stateBefore = manager.connectionState

        for fingerprint in [nil, "", "  "] as [String?] {
            do {
                try await manager.connect(
                    hosts: ["127.0.0.1"], port: server.port, token: "secret-token",
                    certFingerprint: fingerprint)
                Issue.record("expected connect() to refuse a pin-less record")
            } catch let error as WebSocketTransportError {
                #expect(error.isMissingCertificatePin)
                #expect(ConnectionFailureView.isCertificateMismatchMessage(error.localizedDescription))
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }

        // Admission fails before the race: no state adopted, no socket dialed.
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.acceptedCount == 0)
        #expect(manager.connectionState == stateBefore)
        #expect(manager.token != "secret-token")
    }

    /// Regression for monorepo#4185: a pairing attempt (QR / manual token /
    /// intent:// link all funnel into `connect()`) that fails while a live
    /// connection is active must NOT strand the app in `.connecting` on a
    /// dead socket — the existing connection keeps serving.
    @Test @MainActor func failedPairingOverLiveConnectionKeepsItServing() async throws {
        let plaintextWasAllowed = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(plaintextWasAllowed) }
        let manager = ConnectionManager.shared
        let server = try await LoopbackWebSocketServer.start()
        defer {
            manager.disconnect()
            server.stop()
        }

        try await manager.connect(
            hosts: ["127.0.0.1"], port: server.port, token: "live-token")
        #expect(manager.connectionState == .connected)

        let deadPort = try await Self.unusedLoopbackPort()
        await #expect(throws: (any Error).self) {
            try await manager.connect(
                hosts: ["127.0.0.1"], port: deadPort, token: "new-token")
        }

        // The live connection was never torn down: state and target are
        // untouched, and the socket still serves a round-trip.
        #expect(manager.connectionState == .connected)
        #expect(manager.port == server.port)
        #expect(manager.token == "live-token")
        let result = try await manager.request("system.status")
        #expect(result is [String: Any])
    }

    /// A failed pairing attempt over a live connection must leave the live
    /// connection's `certMismatches` bookkeeping untouched: the entry-point
    /// reset (different target) must not wipe it, and mismatches observed by
    /// the failed race must not stick to the preserved connection.
    @Test @MainActor func failedPairingOverLiveConnectionKeepsCertMismatches() async throws {
        let plaintextWasAllowed = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(plaintextWasAllowed) }
        let manager = ConnectionManager.shared
        let server = try await LoopbackWebSocketServer.start()
        defer {
            manager.disconnect()
            server.stop()
        }

        try await manager.connect(
            hosts: ["127.0.0.1"], port: server.port, token: "live-token")
        #expect(manager.connectionState == .connected)
        let liveMismatches = [HostCertMismatch(host: "127.0.0.1", fingerprint: "aa:bb")]
        manager.certMismatches = liveMismatches

        let deadPort = try await Self.unusedLoopbackPort()
        await #expect(throws: (any Error).self) {
            try await manager.connect(
                hosts: ["127.0.0.1"], port: deadPort, token: "new-token")
        }

        #expect(manager.certMismatches == liveMismatches)
    }

    /// The success side of the same flow: pairing over a live connection
    /// adopts the new target only once the replacement socket is
    /// established, and the new connection serves round-trips.
    @Test @MainActor func successfulPairingOverLiveConnectionAdoptsNewTarget() async throws {
        let plaintextWasAllowed = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(plaintextWasAllowed) }
        let manager = ConnectionManager.shared
        let serverA = try await LoopbackWebSocketServer.start()
        let serverB = try await LoopbackWebSocketServer.start()
        defer {
            manager.disconnect()
            serverA.stop()
            serverB.stop()
        }

        try await manager.connect(
            hosts: ["127.0.0.1"], port: serverA.port, token: "token-a")
        #expect(manager.connectionState == .connected)

        try await manager.connect(
            hosts: ["127.0.0.1"], port: serverB.port, token: "token-b")

        #expect(manager.connectionState == .connected)
        #expect(manager.port == serverB.port)
        #expect(manager.token == "token-b")
        let result = try await manager.request("system.status")
        #expect(result is [String: Any])
    }

    /// A tunnel dialer that reports a certificate mismatch only after a delay
    /// the race's loser cancellation cannot cut short, so a direct candidate
    /// wins first and the mismatch is reported by the background drain.
    private nonisolated struct SlowMismatchTunnelDialer: TunnelDialing {
        let fingerprint: String
        func open(tcAddress: String, remotePort: Int) async throws -> any TunnelSession {
            _ = await Task.detached {
                try? await Task.sleep(for: .milliseconds(300))
            }.value
            throw WebSocketTransportError.certificateMismatch(
                host: ConnectionManager.tunnelCandidateLabel, fingerprint: fingerprint)
        }
    }

    /// A preserving connect() retires the old connection — advancing the
    /// connection generation — only AFTER its race is won. A slower losing
    /// candidate's certificate mismatch, reported by the background drain,
    /// must still reach `certMismatches`: the race was not superseded.
    @Test @MainActor func successfulPairingOverLiveConnectionKeepsLateLoserMismatch() async throws {
        let plaintextWasAllowed = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(plaintextWasAllowed) }
        let manager = ConnectionManager.shared
        let serverA = try await LoopbackWebSocketServer.start()
        let serverB = try await LoopbackWebSocketServer.start()
        let originalDialer = manager.tunnelDialer
        defer {
            manager.tunnelDialer = originalDialer
            manager.disconnect()
            serverA.stop()
            serverB.stop()
        }

        try await manager.connect(
            hosts: ["127.0.0.1"], port: serverA.port, token: "token-a")
        #expect(manager.connectionState == .connected)

        manager.tunnelDialer = SlowMismatchTunnelDialer(fingerprint: "cc:dd")
        try await manager.connect(
            hosts: ["127.0.0.1"], port: serverB.port, token: "token-b",
            tcAddress: "tc-slow")
        #expect(manager.connectionState == .connected)
        #expect(manager.port == serverB.port)
        #expect(manager.token == "token-b")

        let expected = [HostCertMismatch(
            host: ConnectionManager.tunnelCandidateLabel, fingerprint: "cc:dd")]
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, manager.certMismatches != expected {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(manager.certMismatches == expected)
    }

    /// Two overlapping pairing attempts over a live connection: the OLDER
    /// attempt completing first must not install its target and supersede
    /// the newer one. Preserving connects don't tear down (and so don't
    /// advance the generation) up front, so ordering is carried by the
    /// connect-attempt counter: the older attempt is superseded, the newer
    /// one adopts its target.
    @Test @MainActor func olderOverlappingPairingAttemptDoesNotWin() async throws {
        let plaintextWasAllowed = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(plaintextWasAllowed) }
        let manager = ConnectionManager.shared
        let liveServer = try await LoopbackWebSocketServer.start()
        let olderTarget = try await LoopbackWebSocketServer.start(gated: true)
        let newerTarget = try await LoopbackWebSocketServer.start(gated: true)
        defer {
            manager.disconnect()
            liveServer.stop()
            olderTarget.stop()
            newerTarget.stop()
        }

        try await manager.connect(
            hosts: ["127.0.0.1"], port: liveServer.port, token: "live-token")
        #expect(manager.connectionState == .connected)

        // Both attempts hang in their WS handshake until their server opens.
        let older = Task {
            try await manager.connect(
                hosts: ["127.0.0.1"], port: olderTarget.port, token: "token-old")
        }
        try await Task.sleep(for: .milliseconds(100))
        let newer = Task {
            try await manager.connect(
                hosts: ["127.0.0.1"], port: newerTarget.port, token: "token-new")
        }
        try await Task.sleep(for: .milliseconds(100))

        // The older attempt completes its handshake FIRST — it must be
        // superseded rather than install token-old and kill the newer one.
        olderTarget.open()
        await #expect(throws: (any Error).self) { try await older.value }
        #expect(manager.token != "token-old")

        newerTarget.open()
        try await newer.value

        #expect(manager.connectionState == .connected)
        #expect(manager.port == newerTarget.port)
        #expect(manager.token == "token-new")
        let result = try await manager.request("system.status")
        #expect(result is [String: Any])
    }

    /// A failed pairing attempt while the manager is reconnecting must keep
    /// the reconnect loop (and its target) alive instead of cancelling it
    /// and stranding the app in `.connecting`.
    @Test @MainActor func failedPairingWhileReconnectingKeepsReconnectLoop() async throws {
        let plaintextWasAllowed = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(plaintextWasAllowed) }
        let manager = ConnectionManager.shared
        let server = try await LoopbackWebSocketServer.start()
        defer {
            manager.disconnect()
            server.stop()
        }

        try await manager.connect(
            hosts: ["127.0.0.1"], port: server.port, token: "live-token")
        #expect(manager.connectionState == .connected)
        let livePort = server.port

        // Kill the live socket so the manager enters its reconnect loop.
        server.stop()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .reconnecting = manager.connectionState { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .reconnecting = manager.connectionState else {
            Issue.record("manager never entered .reconnecting after socket loss")
            return
        }

        let deadPort = try await Self.unusedLoopbackPort()
        await #expect(throws: (any Error).self) {
            try await manager.connect(
                hosts: ["127.0.0.1"], port: deadPort, token: "new-token")
        }

        // Still recovering toward the ORIGINAL target — not stuck in
        // .connecting on the failed pairing target.
        guard case .reconnecting = manager.connectionState else {
            Issue.record("expected .reconnecting, got \(manager.connectionState)")
            return
        }
        #expect(manager.port == livePort)
        #expect(manager.token == "live-token")
    }

    // MARK: - Heartbeat (ios#253)

    /// Manual `HeartbeatClock`: sleepers park until `advance(by:)` moves the
    /// clock past their deadline; cancellation removes them. Tests observe
    /// what is parked via `pendingDurations`.
    ///
    /// While `holdsCancelledSleepers` is set, a cancelled sleeper is moved to
    /// a held list instead of being resumed, and `releaseHeld(asCompleted:)`
    /// finishes it later — either as a sleep that had already completed
    /// when the cancellation arrived, or as the cancellation itself. That
    /// pins the wake of a retired heartbeat task to a chosen point in the
    /// test.
    private nonisolated final class ManualHeartbeatClock: HeartbeatClock, @unchecked Sendable {
        private struct Sleeper {
            let id: Int
            let duration: Duration
            let deadline: Duration
            let continuation: CheckedContinuation<Void, any Error>
        }
        private struct State {
            var now: Duration = .zero
            var nextID = 0
            var sleepers: [Sleeper] = []
            var held: [Sleeper] = []
            var holdsCancelledSleepers = false
        }

        private let lock = OSAllocatedUnfairLock(initialState: State())

        /// Requested durations of the parked sleepers, in registration order.
        var pendingDurations: [Duration] { lock.withLock { $0.sleepers.map(\.duration) } }
        /// Requested durations of the cancelled-but-held sleepers.
        var heldDurations: [Duration] { lock.withLock { $0.held.map(\.duration) } }
        var holdsCancelledSleepers: Bool {
            get { lock.withLock { $0.holdsCancelledSleepers } }
            set { lock.withLock { $0.holdsCancelledSleepers = newValue } }
        }

        func sleep(for duration: Duration) async throws {
            let id = lock.withLock { state in
                state.nextID += 1
                return state.nextID
            }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, any Error>) in
                    let parked = lock.withLock { state in
                        let sleeper = Sleeper(
                            id: id, duration: duration, deadline: state.now + duration,
                            continuation: continuation)
                        if Task.isCancelled {
                            guard state.holdsCancelledSleepers else { return false }
                            state.held.append(sleeper)
                        } else {
                            state.sleepers.append(sleeper)
                        }
                        return true
                    }
                    if !parked { continuation.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                let cancelled = lock.withLock { state -> Sleeper? in
                    guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
                        return nil
                    }
                    let sleeper = state.sleepers.remove(at: index)
                    if state.holdsCancelledSleepers {
                        state.held.append(sleeper)
                        return nil
                    }
                    return sleeper
                }
                cancelled?.continuation.resume(throwing: CancellationError())
            }
        }

        /// Finishes every held sleeper: as a normally completed sleep when
        /// `completed`, otherwise as the cancellation that was held back.
        func releaseHeld(asCompleted completed: Bool) {
            let released = lock.withLock { state in
                defer { state.held.removeAll() }
                return state.held
            }
            for sleeper in released {
                if completed {
                    sleeper.continuation.resume()
                } else {
                    sleeper.continuation.resume(throwing: CancellationError())
                }
            }
        }

        func advance(by duration: Duration) {
            let fired = lock.withLock { state in
                state.now += duration
                let now = state.now
                let due = state.sleepers.filter { $0.deadline <= now }
                state.sleepers.removeAll { $0.deadline <= now }
                return due
            }
            for sleeper in fired { sleeper.continuation.resume() }
        }
    }

    /// Counts connection teardowns — entries into `.reconnecting` from any
    /// other state — for the duration of a test.
    @MainActor private final class DisconnectCounter {
        private(set) var count = 0
        private var wasReconnecting: Bool
        private var cancellable: AnyCancellable?

        init(_ manager: ConnectionManager) {
            if case .reconnecting = manager.connectionState {
                wasReconnecting = true
            } else {
                wasReconnecting = false
            }
            cancellable = manager.connectionStatePublisher.sink { [weak self] state in
                guard let self else { return }
                let isReconnecting: Bool
                if case .reconnecting = state { isReconnecting = true } else { isReconnecting = false }
                if isReconnecting, !self.wasReconnecting { self.count += 1 }
                self.wasReconnecting = isReconnecting
            }
        }
    }

    /// Polls `condition` (real time) until it holds or `timeout` elapses;
    /// the caller asserts afterwards so a miss reports the actual values.
    @MainActor private static func settle(
        timeout: Duration = .seconds(3), until condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// ios#253: after the app was suspended in the background the heartbeat
    /// wakes with a gap far beyond the pong timeout. That must trigger a
    /// probe, not a disconnect: the socket is alive, the pong arrives, and
    /// the connection keeps serving.
    @Test @MainActor func heartbeatGapBeyondTimeoutProbesInsteadOfDisconnecting() async throws {
        let plaintextWasAllowed = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(plaintextWasAllowed) }
        let manager = ConnectionManager.shared
        let clock = ManualHeartbeatClock()
        let server = try await LoopbackWebSocketServer.start(pongs: .replied)
        let originalClock = manager.heartbeatClock
        manager.heartbeatClock = clock
        defer {
            manager.disconnect()
            manager.heartbeatClock = originalClock
            server.stop()
        }

        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "token")
        #expect(manager.connectionState == .connected)
        let disconnects = DisconnectCounter(manager)
        try await Self.settle { clock.pendingDurations == [ConnectionManager.heartbeatInterval] }

        // Suspended for two minutes: the cadence sleep resumes long after
        // the probe timeout would have elapsed since the last pong.
        clock.advance(by: .seconds(120))
        try await Self.settle {
            server.pingsReceived == 1
                && clock.pendingDurations == [ConnectionManager.heartbeatInterval]
        }
        #expect(server.pingsReceived == 1)
        #expect(clock.pendingDurations == [ConnectionManager.heartbeatInterval])
        #expect(disconnects.count == 0)
        #expect(manager.connectionState == .connected)
        let result = try await manager.request("system.status")
        #expect(result is [String: Any])
    }

    /// A probe the daemon never answers is the only thing that may tear the
    /// connection down: once the probe deadline passes, exactly one
    /// disconnect follows (and the reconnect loop takes over).
    @Test @MainActor func unansweredProbeDisconnectsOnce() async throws {
        let plaintextWasAllowed = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(plaintextWasAllowed) }
        let manager = ConnectionManager.shared
        let clock = ManualHeartbeatClock()
        let server = try await LoopbackWebSocketServer.start(pongs: .withheld)
        let originalClock = manager.heartbeatClock
        manager.heartbeatClock = clock
        defer {
            manager.disconnect()
            manager.heartbeatClock = originalClock
            server.stop()
        }

        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "token")
        #expect(manager.connectionState == .connected)
        let disconnects = DisconnectCounter(manager)
        try await Self.settle { clock.pendingDurations == [ConnectionManager.heartbeatInterval] }

        clock.advance(by: ConnectionManager.heartbeatInterval)
        try await Self.settle {
            server.pingsReceived == 1
                && clock.pendingDurations == [ConnectionManager.heartbeatProbeTimeout]
        }
        #expect(server.pingsReceived == 1)
        #expect(clock.pendingDurations == [ConnectionManager.heartbeatProbeTimeout])
        // Probe in flight, deadline not reached: still connected.
        #expect(disconnects.count == 0)
        #expect(manager.connectionState == .connected)

        clock.advance(by: ConnectionManager.heartbeatProbeTimeout)
        // The reconnect loop re-establishes against the same server and
        // arms a fresh heartbeat; no second teardown follows.
        try await Self.settle(timeout: .seconds(5)) {
            manager.connectionState == .connected
                && clock.pendingDurations == [ConnectionManager.heartbeatInterval]
        }
        #expect(disconnects.count == 1)
        #expect(manager.connectionState == .connected)
        #expect(clock.pendingDurations == [ConnectionManager.heartbeatInterval])
    }

    /// A probe in flight when its connection is retired (pairing a new
    /// daemon over the live connection advances the generation) belongs to
    /// the old generation: its outcome neither tears down nor vouches for
    /// the replacement, whose own heartbeat runs undisturbed.
    @Test @MainActor func probeOfRetiredGenerationIsIgnored() async throws {
        let plaintextWasAllowed = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(plaintextWasAllowed) }
        let manager = ConnectionManager.shared
        let clock = ManualHeartbeatClock()
        let serverA = try await LoopbackWebSocketServer.start(pongs: .withheld)
        let serverB = try await LoopbackWebSocketServer.start(pongs: .replied)
        let originalClock = manager.heartbeatClock
        manager.heartbeatClock = clock
        defer {
            manager.disconnect()
            manager.heartbeatClock = originalClock
            serverA.stop()
            serverB.stop()
        }

        try await manager.connect(hosts: ["127.0.0.1"], port: serverA.port, token: "token-a")
        #expect(manager.connectionState == .connected)
        let disconnects = DisconnectCounter(manager)
        try await Self.settle { clock.pendingDurations == [ConnectionManager.heartbeatInterval] }

        clock.advance(by: ConnectionManager.heartbeatInterval)
        try await Self.settle {
            serverA.pingsReceived == 1
                && clock.pendingDurations == [ConnectionManager.heartbeatProbeTimeout]
        }
        #expect(serverA.pingsReceived == 1)

        try await manager.connect(hosts: ["127.0.0.1"], port: serverB.port, token: "token-b")
        #expect(manager.connectionState == .connected)
        #expect(manager.port == serverB.port)
        // The retired probe is gone; only the replacement's cadence is armed.
        try await Self.settle { clock.pendingDurations == [ConnectionManager.heartbeatInterval] }
        #expect(clock.pendingDurations == [ConnectionManager.heartbeatInterval])

        // Passing the retired probe's deadline changes nothing for the
        // replacement: its own probe goes out and is answered.
        clock.advance(by: ConnectionManager.heartbeatProbeTimeout)
        try await Self.settle {
            serverB.pingsReceived == 1
                && clock.pendingDurations == [ConnectionManager.heartbeatInterval]
        }
        #expect(serverA.pingsReceived == 1)
        #expect(serverB.pingsReceived == 1)
        #expect(disconnects.count == 0)
        #expect(manager.connectionState == .connected)
        #expect(manager.port == serverB.port)
    }

    /// The retired generation's pong may also arrive late as a SUCCESS: A's
    /// probe is answered but completes only after B has been adopted. That
    /// success is ignored — it neither counts for B nor spares B its own
    /// probe, which still times out when B never answers.
    @Test @MainActor func latePongOfRetiredGenerationIsIgnored() async throws {
        let manager = ConnectionManager.shared
        let clock = ManualHeartbeatClock()
        let serverA = try await LoopbackWebSocketServer.start(pongs: .replied)
        let serverB = try await LoopbackWebSocketServer.start(pongs: .withheld)
        let originalClock = manager.heartbeatClock
        manager.heartbeatClock = clock
        defer {
            clock.holdsCancelledSleepers = false
            manager.disconnect()
            clock.releaseHeld(asCompleted: false)
            manager.heartbeatClock = originalClock
            serverA.stop()
            serverB.stop()
        }

        try await manager.connect(hosts: ["127.0.0.1"], port: serverA.port, token: "token-a")
        #expect(manager.connectionState == .connected)
        let disconnects = DisconnectCounter(manager)
        try await Self.settle { clock.pendingDurations == [ConnectionManager.heartbeatInterval] }

        // A answers the ping, which cancels the probe's deadline sleeper;
        // holding that sleeper keeps the probe from completing, parking A's
        // success until released.
        clock.holdsCancelledSleepers = true
        clock.advance(by: ConnectionManager.heartbeatInterval)
        try await Self.settle {
            serverA.pingsReceived == 1
                && clock.heldDurations == [ConnectionManager.heartbeatProbeTimeout]
        }
        #expect(clock.heldDurations == [ConnectionManager.heartbeatProbeTimeout])
        #expect(clock.pendingDurations.isEmpty)

        try await manager.connect(hosts: ["127.0.0.1"], port: serverB.port, token: "token-b")
        #expect(manager.connectionState == .connected)
        #expect(manager.port == serverB.port)
        clock.holdsCancelledSleepers = false
        try await Self.settle { clock.pendingDurations == [ConnectionManager.heartbeatInterval] }

        // A's success lands now, after B's adoption.
        clock.releaseHeld(asCompleted: false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(clock.heldDurations.isEmpty)
        #expect(disconnects.count == 0)
        #expect(manager.connectionState == .connected)
        #expect(manager.port == serverB.port)

        // B still has to answer its own probe, and does not.
        clock.advance(by: ConnectionManager.heartbeatInterval)
        try await Self.settle {
            serverB.pingsReceived == 1
                && clock.pendingDurations == [ConnectionManager.heartbeatProbeTimeout]
        }
        #expect(serverB.pingsReceived == 1)
        clock.advance(by: ConnectionManager.heartbeatProbeTimeout)
        try await Self.settle(timeout: .seconds(5)) {
            manager.connectionState == .connected
                && clock.pendingDurations == [ConnectionManager.heartbeatInterval]
        }
        #expect(disconnects.count == 1)
        #expect(serverA.pingsReceived == 1)
        #expect(serverB.pingsReceived == 1)
        #expect(manager.port == serverB.port)
    }

    /// The automatic reconnect keeps the connection generation. A cadence
    /// sleep that completed just as the socket dropped must not, when its
    /// retired loop finally wakes after the reconnect, probe the replacement
    /// from a cancelled task and tear the healthy replacement down.
    @Test @MainActor func lateCadenceWakeAfterAutomaticReconnectDoesNotProbe() async throws {
        let manager = ConnectionManager.shared
        let clock = ManualHeartbeatClock()
        let server = try await LoopbackWebSocketServer.start(pongs: .replied)
        let originalClock = manager.heartbeatClock
        manager.heartbeatClock = clock
        defer {
            clock.holdsCancelledSleepers = false
            manager.disconnect()
            clock.releaseHeld(asCompleted: false)
            manager.heartbeatClock = originalClock
            server.stop()
        }

        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "token")
        #expect(manager.connectionState == .connected)
        let disconnects = DisconnectCounter(manager)
        try await Self.settle { clock.pendingDurations == [ConnectionManager.heartbeatInterval] }

        // Drop the socket server-side while the cadence sleep is parked; the
        // teardown cancels the heartbeat, and the clock holds that wake back
        // until the automatic reconnect has armed the replacement's heartbeat.
        clock.holdsCancelledSleepers = true
        server.dropClients()
        try await Self.settle(timeout: .seconds(5)) {
            clock.heldDurations == [ConnectionManager.heartbeatInterval]
                && manager.connectionState == .connected
                && clock.pendingDurations == [ConnectionManager.heartbeatInterval]
        }
        clock.holdsCancelledSleepers = false
        #expect(clock.heldDurations == [ConnectionManager.heartbeatInterval])
        #expect(manager.connectionState == .connected)
        #expect(disconnects.count == 1)
        #expect(server.pingsReceived == 0)

        // The retired loop's sleep had completed before the cancellation:
        // release it as such. It must do nothing.
        clock.releaseHeld(asCompleted: true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(disconnects.count == 1)
        #expect(manager.connectionState == .connected)
        #expect(server.pingsReceived == 0)

        // Only the replacement's own heartbeat probes.
        clock.advance(by: ConnectionManager.heartbeatInterval)
        try await Self.settle {
            server.pingsReceived == 1
                && clock.pendingDurations == [ConnectionManager.heartbeatInterval]
        }
        #expect(server.pingsReceived == 1)
        #expect(disconnects.count == 1)
        #expect(manager.connectionState == .connected)
    }

    /// Normal operation: one answered probe per interval, none early.
    @Test @MainActor func heartbeatProbesOncePerInterval() async throws {
        let plaintextWasAllowed = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(plaintextWasAllowed) }
        let manager = ConnectionManager.shared
        let clock = ManualHeartbeatClock()
        let server = try await LoopbackWebSocketServer.start(pongs: .replied)
        let originalClock = manager.heartbeatClock
        manager.heartbeatClock = clock
        defer {
            manager.disconnect()
            manager.heartbeatClock = originalClock
            server.stop()
        }

        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "token")
        #expect(manager.connectionState == .connected)
        let disconnects = DisconnectCounter(manager)
        try await Self.settle { clock.pendingDurations == [ConnectionManager.heartbeatInterval] }

        for expected in 1...2 {
            clock.advance(by: ConnectionManager.heartbeatInterval)
            try await Self.settle {
                server.pingsReceived == expected
                    && clock.pendingDurations == [ConnectionManager.heartbeatInterval]
            }
            #expect(server.pingsReceived == expected)
        }

        clock.advance(by: ConnectionManager.heartbeatInterval - .seconds(1))
        try await Task.sleep(for: .milliseconds(100))
        #expect(server.pingsReceived == 2)

        clock.advance(by: .seconds(1))
        try await Self.settle {
            server.pingsReceived == 3
                && clock.pendingDurations == [ConnectionManager.heartbeatInterval]
        }
        #expect(server.pingsReceived == 3)
        #expect(disconnects.count == 0)
        #expect(manager.connectionState == .connected)
    }
}

