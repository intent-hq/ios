// TailcatTunnelSession only compiles where TailcatKit links (no xros slice).
#if canImport(TailcatKit)

import Foundation
import os
import Testing
@testable import Intent

/// Teardown contract of `TailcatTunnelSession` over injected fakes standing
/// in for the gomobile client/forwarder: exactly-once close, partial
/// construction, and blocking closes staying off the caller's executor.
struct TailcatTunnelSessionTests {
    /// Fake gomobile handle: counts `close()` calls, appends its name to a
    /// shared order log, and optionally blocks inside `close()` until the
    /// gate is signalled (a stand-in for a Go-side close waiting on the
    /// startup mutex).
    private nonisolated final class FakeHandle: TunnelClientHandle, TunnelForwarderHandle,
        @unchecked Sendable
    {
        private struct State { var closeCount = 0; var closeEntered = false }
        private let name: String
        private let log: OSAllocatedUnfairLock<[String]>
        private let gate: DispatchSemaphore?
        private let state = OSAllocatedUnfairLock(initialState: State())
        private let localPort: Int

        init(
            _ name: String, log: OSAllocatedUnfairLock<[String]>, localPort: Int = 0,
            blockingOn gate: DispatchSemaphore? = nil
        ) {
            self.name = name
            self.log = log
            self.localPort = localPort
            self.gate = gate
        }

        var closeCount: Int { state.withLock { $0.closeCount } }
        var closeEntered: Bool { state.withLock { $0.closeEntered } }

        func port() -> Int { localPort }

        func close() throws {
            state.withLock {
                $0.closeCount += 1
                $0.closeEntered = true
            }
            log.withLock { $0.append(name) }
            gate?.wait()
        }
    }

    /// Polls `condition` off the main actor until it holds or `timeout`
    /// elapses.
    private nonisolated static func eventually(
        within timeout: Duration, _ condition: @Sendable () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// Concurrent callers race `close()`: the handles must be closed exactly
    /// once, forwarder before client (the forwarder rides the client's tunnel).
    @Test func concurrentClosesCloseEachHandleOnce() async {
        let log = OSAllocatedUnfairLock<[String]>(initialState: [])
        let client = FakeHandle("client", log: log)
        let forwarder = FakeHandle("forwarder", log: log, localPort: 4242)
        let session = TailcatTunnelSession(client: client, forwarder: forwarder)
        #expect(session.localPort == 4242)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { await session.close() }
            }
        }
        await session.close()

        #expect(client.closeCount == 1)
        #expect(forwarder.closeCount == 1)
        #expect(log.withLock { $0 } == ["forwarder", "client"])
    }

    /// A partially constructed session (client dialed, no forwarder) tears
    /// down only what exists.
    @Test func partialConstructionClosesOnlyTheClient() async {
        let log = OSAllocatedUnfairLock<[String]>(initialState: [])
        let client = FakeHandle("client", log: log)
        let session = TailcatTunnelSession(client: client, forwarder: nil)
        #expect(session.localPort == 0)

        await session.close()
        await session.close()

        #expect(client.closeCount == 1)
        #expect(log.withLock { $0 } == ["client"])
    }

    /// Teardown must not be skipped because the closing task was cancelled:
    /// an already-cancelled caller still releases both handles.
    @Test func closeReleasesHandlesWhenCallerIsCancelled() async {
        let log = OSAllocatedUnfairLock<[String]>(initialState: [])
        let client = FakeHandle("client", log: log)
        let forwarder = FakeHandle("forwarder", log: log, localPort: 1)
        let session = TailcatTunnelSession(client: client, forwarder: forwarder)

        let closing = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await session.close()
        }
        await closing.value

        #expect(client.closeCount == 1)
        #expect(forwarder.closeCount == 1)
    }

    /// The gomobile closes can block for seconds (Go-side startup mutex); a
    /// `close()` awaited from the main actor must park the blocking call on
    /// a global queue, leaving the main actor free to run other work.
    /// nonisolated: the probe below is judged from off the main actor, so a
    /// stalled main actor fails the test instead of hanging it.
    @Test nonisolated func blockingCloseDoesNotStallCallersExecutor() async {
        let log = OSAllocatedUnfairLock<[String]>(initialState: [])
        let gate = DispatchSemaphore(value: 0)
        let client = FakeHandle("client", log: log, blockingOn: gate)
        let session = TailcatTunnelSession(client: client, forwarder: nil)

        let closing = Task { @MainActor in await session.close() }
        let entered = await Self.eventually(within: .seconds(5)) { client.closeEntered }
        #expect(entered, "fake close never entered")

        let probeRan = OSAllocatedUnfairLock(initialState: false)
        Task { @MainActor in probeRan.withLock { $0 = true } }
        let mainResponsive = await Self.eventually(within: .seconds(2)) { probeRan.withLock { $0 } }
        #expect(mainResponsive, "blocking close ran on the main actor and stalled it")

        gate.signal()
        await closing.value
        #expect(client.closeCount == 1)
    }
}

#endif
