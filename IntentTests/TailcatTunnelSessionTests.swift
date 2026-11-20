#if canImport(TailcatKit)

    import Foundation
    @testable import Intent
    import os
    import Testing

    struct TailcatTunnelSessionTests {
        private struct FakeHandleState {
            var closeCount = 0
            var closeEntered = false
        }

        nonisolated private final class FakeHandle: TunnelClientHandle, TunnelForwarderHandle,
            @unchecked Sendable {
            private let name: String
            private let log: OSAllocatedUnfairLock<[String]>
            private let gate: DispatchSemaphore?
            private let state = OSAllocatedUnfairLock(initialState: FakeHandleState())
            private let localPort: Int

            init(
                _ name: String,
                log: OSAllocatedUnfairLock<[String]>,
                localPort: Int = 0,
                blockingOn gate: DispatchSemaphore? = nil
            ) {
                self.name = name
                self.log = log
                self.localPort = localPort
                self.gate = gate
            }

            var closeCount: Int {
                state.withLock { $0.closeCount }
            }

            var closeEntered: Bool {
                state.withLock { $0.closeEntered }
            }

            func port() -> Int {
                localPort
            }

            func close() {
                state.withLock { state in
                    state.closeCount += 1
                    state.closeEntered = true
                }
                log.withLock { $0.append(name) }
                _ = gate?.wait(timeout: .now() + Self.maxBlock)
            }

            static let maxBlock: DispatchTimeInterval = .seconds(10)
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

        @Test func concurrentClosesCloseEachHandleOnce() async {
            let log = OSAllocatedUnfairLock<[String]>(initialState: [])
            let client = FakeHandle("client", log: log)
            let forwarder = FakeHandle("forwarder", log: log, localPort: 4242)
            let session = TailcatTunnelSession(client: client, forwarder: forwarder)
            #expect(session.localPort == 4242)

            await withTaskGroup(of: Void.self) { group in
                for _ in 0 ..< 8 {
                    group.addTask { await session.close() }
                }
            }
            await session.close()

            #expect(client.closeCount == 1)
            #expect(forwarder.closeCount == 1)
            #expect(log.withLock { $0 } == ["forwarder", "client"])
        }

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

        @Test func blockingCloseDoesNotStallCallersExecutor() async {
            let log = OSAllocatedUnfairLock<[String]>(initialState: [])
            let gate = DispatchSemaphore(value: 0)
            let client = FakeHandle("client", log: log, blockingOn: gate)
            let session = TailcatTunnelSession(client: client, forwarder: nil)

            let verdict = Task.detached { () -> (entered: Bool, mainResponsive: Bool) in
                let closing = Task { @MainActor in await session.close() }
                let entered = await Self.eventually(within: .seconds(5)) { client.closeEntered }

                let probeRan = OSAllocatedUnfairLock(initialState: false)
                Task { @MainActor in probeRan.withLock { $0 = true } }
                let mainResponsive = await Self.eventually(within: .seconds(2)) { probeRan.withLock { $0 } }

                gate.signal()
                await closing.value
                return (entered, mainResponsive)
            }
            let (entered, mainResponsive) = await verdict.value

            #expect(entered, "fake close never entered")
            #expect(mainResponsive, "blocking close ran on the main actor and stalled it")
            #expect(client.closeCount == 1)
        }
    }

#endif
