import Foundation
@testable import Intent
import Synchronization
import Testing

struct DiagnosticConcurrencyTests {
    @Test func concurrentWritersAndSnapshotsRemainOrderedAndBounded() async throws {
        let storage = DiagnosticTestStorage()
        let store = DiagnosticStore(storage: storage)
        let iterations = 100
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask { store.record(DiagnosticFixtures.event()) }
                group.addTask { _ = await store.snapshot() }
            }
        }
        let snapshot = await store.snapshot()
        let records = try DiagnosticFixtures.records(snapshot)
        #expect(records.reduce(0) { $0 + $1.count } == UInt64(iterations))
        #expect(snapshot.jsonLines.count <= DiagnosticLimits.maximumHistoryBytes)
        #expect(records.allSatisfy { $0.isValid })
        #expect(!storage.state.withLock { $0.touchedMainThread })
    }

    @Test func queueIsBoundedAndOverflowCannotMergeAcrossLostEvents() {
        let intake = DiagnosticIntake(limits: DiagnosticLimits(pending: 1)) { Date() }
        #expect(intake.append(DiagnosticFixtures.event(), scope: nil))
        #expect(!intake.append(DiagnosticFixtures.event(operation: .workspaceCreate), scope: nil))
        #expect(!intake.append(DiagnosticFixtures.event(), scope: nil))
        #expect(intake.losses().overflow == 2)
        let records = intake.take()
        #expect(records.count == 1)
        #expect(records.first?.count == 1)
    }

    @Test func identicalFloodNeedsOnlyOnePendingSlot() {
        let intake = DiagnosticIntake(limits: DiagnosticLimits(pending: 1)) { Date() }
        let iterations = 10_000
        for _ in 0..<iterations { #expect(intake.append(DiagnosticFixtures.event(), scope: nil)) }
        let records = intake.take()
        #expect(records.count == 1)
        #expect(records.first?.count == UInt64(iterations))
        #expect(intake.losses().overflow == 0)
    }

    @Test func foreignScopesAreRejectedRatherThanPersistingCallerIdentity() async throws {
        let first = DiagnosticStore(storage: DiagnosticTestStorage())
        let second = DiagnosticStore(storage: DiagnosticTestStorage())
        let foreign = try #require(first.makeScope())
        #expect(!second.record(DiagnosticFixtures.event(), scope: foreign))
        let snapshot = await second.snapshot()
        #expect(snapshot.jsonLines.isEmpty)
        #expect(snapshot.metadata.loss.invalidScope == 1)
    }

    @Test func writeFailureKeepsBoundedMemoryAndRecoversWithoutRecursiveLogging() async throws {
        let storage = DiagnosticTestStorage()
        storage.state.withLock { $0.failWrite = true }
        let store = DiagnosticStore(storage: storage, limits: DiagnosticLimits(historyBytes: 2048))
        for _ in 0..<20 { store.record(DiagnosticFixtures.event(), scope: store.makeScope()) }
        let failed = await store.snapshot()
        #expect(failed.metadata.loss.storageUnavailable)
        #expect(failed.jsonLines.count <= 2048)
        #expect(await store.beginReport() == nil)
        storage.state.withLock { $0.failWrite = false }
        let recovered = await store.snapshot()
        #expect(try storage.files.readHistory(maximumBytes: 2048) == recovered.jsonLines)
    }

    @Test func unreadableHistoryIsNotOverwrittenAndRecoveredReadPreservesOrder() async throws {
        let storage = DiagnosticTestStorage()
        let first = DiagnosticStore(storage: storage)
        first.record(DiagnosticFixtures.event())
        let original = await first.snapshot()
        storage.state.withLock { $0.failRead = true; $0.writes = 0 }
        let next = DiagnosticStore(storage: storage)
        next.record(DiagnosticFixtures.event(operation: .workspaceCreate))
        #expect(await next.snapshot().metadata.loss.storageUnavailable)
        #expect(storage.state.withLock { $0.writes } == 0)
        #expect(try storage.files.readHistory(maximumBytes: DiagnosticLimits.maximumHistoryBytes) == original.jsonLines)
        storage.state.withLock { $0.failRead = false }
        let records = try DiagnosticFixtures.records(await next.snapshot())
        #expect(records.map(\.event.operation) == [.workspaceLoad, .workspaceCreate])
    }

    @Test func historyReadRetryCannotRemovePinnedReport() async throws {
        let storage = DiagnosticTestStorage()
        storage.state.withLock { $0.failRead = true }
        let store = DiagnosticStore(storage: storage)
        store.record(DiagnosticFixtures.event())
        let report = try #require(await store.beginReport())
        storage.state.withLock { $0.failRead = false }
        _ = await store.snapshot()
        let entries = try DiagnosticZIPTestReader.extract(Data(contentsOf: report.archiveURL))
        #expect(entries["events.jsonl"] == report.snapshot.jsonLines)
        #expect(await store.endReport(report))
    }

    @Test func failedDeletionIsReportedAndCannotReloadOldHistory() async {
        let storage = DiagnosticTestStorage()
        let store = DiagnosticStore(storage: storage)
        store.record(DiagnosticFixtures.event())
        _ = await store.snapshot()
        storage.state.withLock { $0.failClear = true }
        #expect(!(await store.clearHistory()))
        #expect(await store.snapshot().jsonLines.isEmpty)
        storage.state.withLock { $0.failClear = false }
        #expect(await store.clearHistory())
    }

    @Test func concurrentClearAndRecordingNeverProducesMalformedSnapshots() async throws {
        let store = DiagnosticStore(storage: DiagnosticTestStorage())
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { store.record(DiagnosticFixtures.event()) }
                group.addTask { _ = await store.clearHistory() }
            }
        }
        #expect(await store.clearHistory())
        #expect(await store.snapshot().jsonLines.isEmpty)
        store.record(DiagnosticFixtures.event())
        #expect(try DiagnosticFixtures.records(await store.snapshot()).count == 1)
    }
}
