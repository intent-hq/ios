import Foundation
@testable import Intent
import Testing

@MainActor
struct CoalescedReadTests {
    @Test func invalidateSchedulesOnlyFromIdle() {
        let read = CoalescedRead()
        #expect(read.invalidate())
        #expect(read.phase == .scheduled)
        #expect(!read.invalidate())
        read.settleScheduled()
        #expect(read.phase == .idle)
        #expect(read.invalidate())
    }

    @Test func invalidationDuringPassEarnsOneTrailingPass() async {
        let read = CoalescedRead()
        var passes = 0
        await read.run(isCurrent: { true }) { _ in
            passes += 1
            _ = read.invalidate()
        }
        #expect(passes == 2)
        #expect(read.phase == .idle)
    }

    @Test func concurrentRunJoinsInsteadOfStartingAnotherPass() async {
        let read = CoalescedRead()
        let gate = AsyncGate()
        var passes = 0
        let first = Task { await read.run(isCurrent: { true }) { _ in passes += 1; await gate.wait() } }
        while passes == 0 { await Task.yield() }
        let second = Task { await read.run(isCurrent: { true }) { _ in passes += 1 } }
        await Task.yield()
        gate.open()
        await first.value
        await second.value
        #expect(passes == 1)
        #expect(read.phase == .idle)
    }

    @Test func staleOwnerSkipsPass() async {
        let read = CoalescedRead()
        var passes = 0
        await read.run(isCurrent: { false }) { _ in passes += 1 }
        #expect(passes == 0)
        #expect(read.phase == .idle)
    }

    @Test func cancelRetiresRunningReadAndAdvancesRevision() async {
        let read = CoalescedRead()
        let gate = AsyncGate()
        var observed: [Int] = []
        let running = Task { await read.run(isCurrent: { true }) { revision in observed.append(revision); await gate.wait() } }
        while observed.isEmpty { await Task.yield() }
        let before = read.revision
        read.cancel()
        #expect(read.phase == .idle)
        #expect(read.revision != before)
        gate.open()
        await running.value
        #expect(observed == [before])
        #expect(read.phase == .idle)
    }
}

@MainActor
private final class AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
