#if canImport(TailcatKit)

import Foundation
@testable import Intent
import os
import TailcatKit
import Testing

struct TailcatKitSmokeTests {
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
            do {
                received.append(try conn.read(message.count - received.count))
            } catch where error.localizedDescription == "EOF" {
                break
            }
        }
        #expect(received == message)
    }
}

struct TailcatDialHandleTests {
    private struct BlockingCloseState {
        var closeEntered = false
        var closeFinished = false
        var releaseSent = false
    }

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
