// TailcatKit only links on iOS (no xros slice; platformFilters in the
// project) — compile these smoke tests out where it is absent.
#if canImport(TailcatKit)

import Foundation
@testable import Intent
import os
import TailcatKit
import Testing

/// Smoke tests for the vendored TailcatKit.xcframework (gomobile bind
/// of TailcatKit/, wrapping github.com/tailscale/tailcat).
///
/// The byte-exchange test needs a running tailcat echo server to dial:
/// the CI harness starts TailcatKit/cmd/tcecho and passes its token via
/// the TAILCAT_SMOKE_TOKEN environment variable. Without the variable
/// that test is skipped, but the API-surface tests still run, verifying
/// the framework links and its Swift projection behaves.
struct TailcatKitSmokeTests {
    // nonisolated: the .enabled(if:) trait evaluates in a Sendable
    // closure, which cannot touch main-actor-isolated state under the
    // project's default MainActor isolation.
    nonisolated static var smokeToken: String? {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["TAILCAT_SMOKE_TOKEN"], !token.isEmpty else { return nil }
        return token
    }

    @Test func invalidPortIsRejected() throws {
        let client = try #require(TailcatkitNewClient("tc-not-a-real-token"))
        defer { try? client.close() }
        #expect(throws: (any Error).self) {
            try client.dial(0, timeoutMs: 1000)
        }
    }

    @Test func invalidForwardPortIsRejected() throws {
        let client = try #require(TailcatkitNewClient("tc-not-a-real-token"))
        defer { try? client.close() }
        #expect(throws: (any Error).self) {
            try client.forward(70_000)
        }
    }

    @Test(.enabled(if: smokeToken != nil))
    func dialEchoAndExchangeBytes() throws {
        let token = try #require(Self.smokeToken)
        let client = try #require(TailcatkitNewClient(token))
        defer { try? client.close() }

        let conn = try client.dial(4711, timeoutMs: 60_000)
        defer { try? conn.close() }

        let message = Data("hello from iOS".utf8)
        try conn.write(message)
        try conn.setDeadlineMs(60_000)

        var received = Data()
        while received.count < message.count {
            // Read throws an error whose description is "EOF" at end of
            // stream (an empty Go slice would bridge to nil NSData and
            // break the throws -> Data projection, so EOF is out-of-band).
            do {
                received.append(try conn.read(message.count - received.count))
            } catch where error.localizedDescription == "EOF" {
                break
            }
        }
        #expect(received == message)
    }
}

/// Ordering logic of the dial-cancellation bridge. Real unused gomobile
/// clients retain framework projection coverage, while the blocking fake
/// makes the off-thread close contract detectable. No network is involved.
struct TailcatDialHandleTests {
    private struct BlockingCloseState {
        var closeEntered = false
        var closeFinished = false
        var releaseSent = false
    }

    /// Stands in for a gomobile close waiting on the Go startup mutex. The
    /// internal timeout is only an emergency fail-safe; tests coordinate entry
    /// and release explicitly, and observe state without blocking an actor.
    nonisolated private final class BlockingCloseClient: TunnelClientHandle, @unchecked Sendable {
        private let releaseGate = DispatchSemaphore(value: 0)
        private let state = OSAllocatedUnfairLock(initialState: BlockingCloseState())

        var closeEntered: Bool {
            state.withLock { $0.closeEntered }
        }

        var closeFinished: Bool {
            state.withLock { $0.closeFinished }
        }

        func close() {
            state.withLock { $0.closeEntered = true }
            _ = releaseGate.wait(timeout: .now() + Self.maximumBlock)
            state.withLock { $0.closeFinished = true }
        }

        func releaseClose() {
            let shouldSignal = state.withLock { state in
                guard !state.releaseSent else { return false }
                state.releaseSent = true
                return true
            }
            if shouldSignal {
                releaseGate.signal()
            }
        }

        private static let maximumBlock: DispatchTimeInterval = .seconds(10)
    }

    /// Polls lock-backed state off the main actor until it changes or the
    /// deadline elapses.
    nonisolated private static func eventually(
        within timeout: Duration,
        _ condition: @Sendable () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    @Test func registerAfterCancelIsRefused() throws {
        let handle = TailcatTunnelDialer.DialHandle()
        let client = try #require(TailcatkitNewClient("tc-not-a-real-token"))
        defer { try? client.close() }

        #expect(!handle.isCancelled)
        handle.cancel()
        #expect(handle.isCancelled)
        #expect(!handle.register(client))
    }

    @Test func registerBeforeCancelIsAccepted() throws {
        let handle = TailcatTunnelDialer.DialHandle()
        let client = try #require(TailcatkitNewClient("tc-not-a-real-token"))
        defer { try? client.close() }

        #expect(handle.register(client))
        #expect(handle.cancelledAt == nil)
        handle.cancel()
        #expect(handle.isCancelled)
        #expect(handle.cancelledAt != nil)
    }

    @Test func cancelIsIdempotent() throws {
        let handle = TailcatTunnelDialer.DialHandle()
        let client = try #require(TailcatkitNewClient("tc-not-a-real-token"))
        defer { try? client.close() }

        #expect(handle.register(client))
        handle.cancel()
        let first = try #require(handle.cancelledAt)
        handle.cancel()
        #expect(handle.cancelledAt == first)
    }

    /// The judge runs detached because this target defaults to MainActor
    /// isolation. A synchronous-close regression blocks only the cancellation
    /// worker; the judge observes that cancel did not return, releases the fake,
    /// awaits cleanup, and then reports the bounded failure back to the test.
    @Test func cancelDoesNotBlockCaller() async {
        let handle = TailcatTunnelDialer.DialHandle()
        let client = BlockingCloseClient()
        #expect(handle.register(client))

        let judge = Task.detached {
            let cancelReturned = OSAllocatedUnfairLock(initialState: false)
            defer { client.releaseClose() }
            DispatchQueue.global(qos: .userInitiated).async { @Sendable in
                handle.cancel()
                cancelReturned.withLock { $0 = true }
            }

            let entered = await Self.eventually(within: .seconds(5)) { client.closeEntered }
            let returned = await Self.eventually(within: .seconds(2)) {
                cancelReturned.withLock { $0 }
            }
            let remainedBlocked = !client.closeFinished

            client.releaseClose()
            let cleanupFinished = await Self.eventually(within: .seconds(5)) { client.closeFinished }
            return (entered, returned, remainedBlocked, cleanupFinished)
        }
        let (entered, returned, remainedBlocked, cleanupFinished) = await judge.value

        #expect(entered, "fake close never entered")
        #expect(returned, "cancel() waited for the blocked close")
        #expect(remainedBlocked, "fake close returned before the test released it")
        #expect(cleanupFinished, "fake close did not finish after release")
    }
}

#endif
