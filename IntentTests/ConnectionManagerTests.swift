import Combine
import Foundation
@testable import Intent
import Network
import os
import Testing

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

        let connectionCancellable = manager.connectionStatePublisher.sink { state in
            receivedConnectionStates.append(state)
        }
        let certCancellable = manager.certMismatchPublisher.sink { mismatchDetected in
            receivedCertMismatches.append(mismatchDetected)
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
            connectionLifetime: nil,
            previousAttempt: 4
        ) == 1)
        #expect(ConnectionManager.reconnectStartingAttempt(
            connectionLifetime: 10,
            previousAttempt: 4
        ) == 1)
        #expect(ConnectionManager.reconnectStartingAttempt(
            connectionLifetime: 9.9,
            previousAttempt: 0
        ) == 2)
        #expect(ConnectionManager.reconnectStartingAttempt(
            connectionLifetime: 1,
            previousAttempt: 4
        ) == 5)
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

    @Test @MainActor func dispatchResponseResolvesCorrectContinuation() async {
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
            _ = try await manager.awaitResponse(id: 7003, timeout: 0.05) { nil }
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
                capture.value = try await manager.awaitResponse(id: 7001, timeout: 0.05) { nil }
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
    @Test @MainActor func perCallTimeoutOverrideHonored() async {
        let manager = ConnectionManager.shared
        let capture = ResponseCapture()
        let pending = Task { @MainActor in
            do {
                capture.value = try await manager.awaitResponse(id: 7002, timeout: 5.0) { nil }
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
}

extension ConnectionManagerTests {
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
        let pendingRequestTimeoutSeconds = 5
        let deadline = ContinuousClock.now + .seconds(pendingRequestTimeoutSeconds)
        while manager.pendingRequests[id] == nil {
            if ContinuousClock.now >= deadline {
                Issue.record("Timed out waiting for pendingRequests[\(id)] to be registered")
                return
            }
            await Task.yield()
        }
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
            #expect(nsError.code == -32_602)
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
            #expect(nsError.code == -32_602)
            #expect(nsError.intentErrorDataCode == nil)
            #expect(!nsError.isEntityNotFound, "a -32602 without data.code must not read as entity-not-found")
        } else {
            Issue.record("Expected error but got success")
        }
    }

    // MARK: - NSError.isEntityNotFound helper

    @Test func isEntityNotFoundRequiresDomainCodeAndDataCode() {
        let notFound = NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [NSError.intentErrorDataCodeKey: "not-found"]
        )
        #expect(notFound.isEntityNotFound)

        let invalidParams = NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [NSError.intentErrorDataCodeKey: "invalid-params"]
        )
        #expect(!invalidParams.isEntityNotFound)

        let bare = NSError(domain: "WebSocket", code: -32_602)
        #expect(!bare.isEntityNotFound)

        let wrongCode = NSError(
            domain: "WebSocket",
            code: -32_603,
            userInfo: [NSError.intentErrorDataCodeKey: "not-found"]
        )
        #expect(!wrongCode.isEntityNotFound)

        let wrongDomain = NSError(
            domain: "SomeOtherDomain",
            code: -32_602,
            userInfo: [NSError.intentErrorDataCodeKey: "not-found"]
        )
        #expect(!wrongDomain.isEntityNotFound)
    }
}
