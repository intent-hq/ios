import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceAuthorityGateTests {
    @Test func releaseResumesParkedWaiters() async {
        let gate = WorkspaceAuthorityGate()
        let waiter = Task { await gate.wait() }
        while !gate.hasWaiters { await Task.yield() }
        gate.release(ready: true)
        #expect(await waiter.value)
        #expect(!gate.hasWaiters)
    }

    @Test func failureRefusesWaitsUntilCleared() async {
        let gate = WorkspaceAuthorityGate()
        let waiter = Task { await gate.wait() }
        while !gate.hasWaiters { await Task.yield() }
        gate.fail()
        #expect(await !waiter.value)
        #expect(await !gate.wait())
        #expect(gate.clearFailure())
        #expect(!gate.clearFailure())
    }

    @Test func resetReleasesWaitersAndClearsFailure() async {
        let gate = WorkspaceAuthorityGate()
        gate.fail()
        gate.reset()
        #expect(!gate.hasFailed)
        let waiter = Task { await gate.wait() }
        while !gate.hasWaiters { await Task.yield() }
        gate.reset()
        #expect(await !waiter.value)
    }

    @Test func cancellationRemovesWaiter() async {
        let gate = WorkspaceAuthorityGate()
        let waiter = Task { await gate.wait() }
        while !gate.hasWaiters { await Task.yield() }
        waiter.cancel()
        #expect(await !waiter.value)
        while gate.hasWaiters { await Task.yield() }
    }
}
