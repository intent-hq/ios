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
        await read.run(isCurrent: { true }, pass: { _ in
            passes += 1
            _ = read.invalidate()
        })
        #expect(passes == 2)
        #expect(read.phase == .idle)
    }

    @Test func concurrentRunJoinsInsteadOfStartingAnotherPass() async {
        let read = CoalescedRead()
        let gate = AsyncGate()
        var passes = 0
        let first = Task { await read.run(isCurrent: { true }, pass: { _ in passes += 1; await gate.wait() }) }
        while passes == 0 { await Task.yield() }
        let second = Task { await read.run(isCurrent: { true }, pass: { _ in passes += 1 }) }
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
        await read.run(isCurrent: { false }, pass: { _ in passes += 1 })
        #expect(passes == 0)
        #expect(read.phase == .idle)
    }

    @Test func cancelRetiresRunningReadAndAdvancesRevision() async {
        let read = CoalescedRead()
        let gate = AsyncGate()
        var observed: [Int] = []
        let running = Task { await read.run(isCurrent: { true }, pass: { revision in observed.append(revision); await gate.wait() }) }
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

    @Test func ownerLearnsOfAnInvalidationAfterItsTrailingPass() async {
        let read = CoalescedRead()
        var passes = 0
        let needsFollowUp = await read.run(isCurrent: { true }, pass: { _ in
            passes += 1
            _ = read.invalidate()
        })
        #expect(passes == 2)
        #expect(needsFollowUp)
        #expect(read.phase == .idle)
        let settled = await read.run(isCurrent: { true }, pass: { _ in passes += 1 })
        #expect(passes == 3)
        #expect(!settled)
    }

    @Test func joinerNeverOwnsTheFollowUp() async {
        let read = CoalescedRead()
        let gate = AsyncGate()
        var passes = 0
        let owner = Task {
            await read.run(isCurrent: { true }, pass: { _ in
                passes += 1
                _ = read.invalidate()
                await gate.wait()
            })
        }
        while passes == 0 { await Task.yield() }
        let joiner = Task { await read.run(isCurrent: { true }, pass: { _ in passes += 100 }) }
        await Task.yield()
        gate.open()
        let ownerNeedsFollowUp = await owner.value
        let joinerNeedsFollowUp = await joiner.value
        #expect(ownerNeedsFollowUp)
        #expect(!joinerNeedsFollowUp)
        #expect(passes == 2)
    }

    @Test func cancelledOrRetiredReadOwesNoFollowUp() async {
        let read = CoalescedRead()
        let gate = AsyncGate()
        var started = false
        let cancelled = Task {
            await read.run(isCurrent: { true }, pass: { _ in
                started = true
                _ = read.invalidate()
                await gate.wait()
            })
        }
        while !started { await Task.yield() }
        read.cancel()
        gate.open()
        let cancelledNeedsFollowUp = await cancelled.value
        #expect(!cancelledNeedsFollowUp)

        var current = true
        let retired = await read.run(isCurrent: { current }, pass: { _ in
            current = false
            _ = read.invalidate()
        })
        #expect(!retired)
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
