import Foundation
@testable import Intent
import Synchronization
import Testing

struct DiagnosticExportTests {
    @Test func exportsReviewedSnapshotNotEventsArrivingAfterReview() async throws {
        let clock = DiagnosticTestClock()
        let limits = DiagnosticLimits(historyBytes: 2048)
        let store = DiagnosticStore(storage: DiagnosticTestStorage(), limits: limits) { clock.now() }
        store.record(DiagnosticFixtures.event())
        let reviewed = await store.snapshot()
        store.record(DiagnosticFixtures.event(operation: .workspaceCreate))
        let current = await store.snapshot()
        #expect(current.metadata.retainedRecords == 2)
        #expect(current.metadata.loss.rotatedRecords == 0)
        #expect(current.jsonLines.count <= limits.historyBytes)
        #expect(current.historyRevision == reviewed.historyRevision)
        guard case .ready(let report) = await store.prepareExport(reviewing: reviewed) else {
            Issue.record("Expected a report for the reviewed snapshot")
            return
        }
        let entries = try DiagnosticZIPTestReader.extract(Data(contentsOf: report.archiveURL))
        #expect(entries["events.jsonl"] == reviewed.jsonLines)
        #expect(entries["metadata.json"] == (try reviewed.metadataJSON()))
        #expect(await store.endReport(report))
    }

    @Test func byteRotationPermanentlyRejectsOldPreviewAndFreshReviewExportsRetainedEvents() async throws {
        let clock = DiagnosticTestClock()
        let storage = DiagnosticTestStorage()
        let limits = DiagnosticLimits(historyBytes: 2048)
        let store = DiagnosticStore(storage: storage, limits: limits) { clock.now() }
        store.record(DiagnosticFixtures.event())
        let reviewed = await store.snapshot()
        #expect(reviewed.metadata.retainedRecords == 1)
        for _ in 0..<20 {
            #expect(store.record(DiagnosticFixtures.event(operation: .workspaceCreate), scope: store.makeScope()))
        }
        let rotated = await store.snapshot()
        let retained = try DiagnosticFixtures.records(rotated)
        #expect(!retained.isEmpty)
        #expect(!retained.contains { $0.event.operation == .workspaceLoad })
        #expect(rotated.metadata.loss.rotatedRecords > 0)
        #expect(rotated.metadata.loss.expiredRecords == 0)
        #expect(rotated.metadata.generatedAt == reviewed.metadata.generatedAt)
        #expect(rotated.jsonLines.count <= limits.historyBytes)
        guard case .needsReview(let updated) = await store.prepareExport(reviewing: reviewed) else {
            Issue.record("Size-evicted records must not be exported from an older preview")
            return
        }
        #expect(updated.jsonLines == rotated.jsonLines)
        let reportDirectory = storage.files.directory.appendingPathComponent("report")
        #expect(!FileManager.default.fileExists(atPath: reportDirectory.path))
        guard case .ready(let report) = await store.prepareExport(reviewing: updated) else {
            Issue.record("A fresh review of retained records must be exportable after size rotation")
            return
        }
        let entries = try DiagnosticZIPTestReader.extract(Data(contentsOf: report.archiveURL))
        #expect(entries["events.jsonl"] == updated.jsonLines)
        #expect(entries["metadata.json"] == (try updated.metadataJSON()))
        #expect(await store.endReport(report))
        guard case .needsReview(let retried) = await store.prepareExport(reviewing: reviewed) else {
            Issue.record("The old preview must stay invalid after a fresh export finishes")
            return
        }
        #expect(retried.jsonLines == updated.jsonLines)
        #expect(!FileManager.default.fileExists(atPath: reportDirectory.path))
    }

    @Test(arguments: [false, true])
    func expiryAndClockRollbackRequireAnotherReview(rollback: Bool) async {
        let clock = DiagnosticTestClock()
        let storage = DiagnosticTestStorage()
        let store = DiagnosticStore(storage: storage) { clock.now() }
        store.record(DiagnosticFixtures.event())
        let reviewed = await store.snapshot()
        clock.advance(rollback ? -1 : DiagnosticLimits.maximumAge)
        guard case .needsReview(let updated) = await store.prepareExport(reviewing: reviewed) else {
            Issue.record("Stale snapshot must not be exported")
            return
        }
        #expect(updated.jsonLines.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: storage.files.directory.appendingPathComponent("report").path))
    }
}

extension DiagnosticExportTests {
    @Test func expiryPurgeThenRollbackNeverResurrectsReviewedEvents() async throws {
        let clock = DiagnosticTestClock()
        let storage = DiagnosticTestStorage()
        let store = DiagnosticStore(storage: storage) { clock.now() }
        store.record(DiagnosticFixtures.event())
        let reviewed = await store.snapshot()
        #expect(reviewed.metadata.retainedRecords == 1)
        clock.advance(DiagnosticLimits.maximumAge)
        let purged = await store.snapshot()
        #expect(purged.jsonLines.isEmpty)
        #expect(purged.historyRevision != reviewed.historyRevision)
        clock.advance(-DiagnosticLimits.maximumAge)
        guard case .needsReview(let updated) = await store.prepareExport(reviewing: reviewed) else {
            Issue.record("Returning to the preview time must not resurrect expired records")
            return
        }
        #expect(updated.metadata.generatedAt == reviewed.metadata.generatedAt)
        #expect(updated.jsonLines.isEmpty)
        #expect(try storage.files.readHistory(maximumBytes: DiagnosticLimits.maximumHistoryBytes).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: storage.files.directory.appendingPathComponent("report").path))
        guard case .needsReview = await store.prepareExport(reviewing: reviewed) else {
            Issue.record("An invalidated preview must remain invalid on retry")
            return
        }
        guard case .ready(let report) = await store.prepareExport(reviewing: updated) else {
            Issue.record("A fresh empty preview must be exportable after rollback")
            return
        }
        let entries = try DiagnosticZIPTestReader.extract(Data(contentsOf: report.archiveURL))
        #expect(entries["events.jsonl"] == Data())
        #expect(await store.endReport(report))
    }

    @Test func futureRecordPurgeInvalidatesReviewWithoutObservedClockRollback() async {
        let clock = DiagnosticTestClock()
        let forward: TimeInterval = 10
        let storage = DiagnosticTestStorage()
        let limits = DiagnosticLimits()
        let intake = DiagnosticIntake(limits: limits) { clock.now() }
        let writer = DiagnosticWriter(storage: storage, intake: intake, limits: limits) { clock.now() }
        #expect(intake.append(DiagnosticFixtures.event(), scope: nil))
        let reviewed = await writer.snapshot()
        clock.advance(forward)
        #expect(intake.append(DiagnosticFixtures.event(operation: .workspaceCreate), scope: nil))
        clock.advance(-forward)
        // No worker ran at the future time: removal itself must rotate the revision.
        let purged = await writer.snapshot()
        #expect(purged.jsonLines == reviewed.jsonLines)
        #expect(purged.metadata.loss.expiredRecords == 1)
        #expect(purged.historyRevision != reviewed.historyRevision)
        clock.advance(forward)
        guard case .needsReview(let updated) = await writer.prepareExport(reviewing: reviewed) else {
            Issue.record("A future-record purge must permanently invalidate older reviews")
            return
        }
        #expect(updated.jsonLines == reviewed.jsonLines)
        #expect(!FileManager.default.fileExists(atPath: storage.files.directory.appendingPathComponent("report").path))
    }

    @Test(arguments: [false, true])
    func observedForwardTimeThenPartialRollbackRequiresReview(observeByExport: Bool) async {
        let clock = DiagnosticTestClock()
        let forward: TimeInterval = 10
        let rollback: TimeInterval = 5
        let storage = DiagnosticTestStorage()
        let store = DiagnosticStore(storage: storage) { clock.now() }
        store.record(DiagnosticFixtures.event())
        let reviewed = await store.snapshot()
        clock.advance(forward)
        if observeByExport {
            guard case .ready(let report) = await store.prepareExport(reviewing: reviewed) else {
                Issue.record("Normal forward time must not invalidate the review")
                return
            }
            #expect(await store.endReport(report))
        } else {
            _ = await store.snapshot()
        }
        clock.advance(-rollback)
        guard case .needsReview(let updated) = await store.prepareExport(reviewing: reviewed) else {
            Issue.record("Rollback must invalidate even when still later than the preview time")
            return
        }
        #expect(updated.metadata.generatedAt > reviewed.metadata.generatedAt)
        #expect(updated.jsonLines == reviewed.jsonLines)
        #expect(updated.historyRevision != reviewed.historyRevision)
        #expect(!FileManager.default.fileExists(atPath: storage.files.directory.appendingPathComponent("report").path))
        clock.advance(rollback)
        guard case .needsReview = await store.prepareExport(reviewing: reviewed) else {
            Issue.record("Catching up to the old clock time must not restore an invalidated review")
            return
        }
    }

    @Test func freshSnapshotAfterPartialRollbackCanBeSharedImmediately() async throws {
        let clock = DiagnosticTestClock()
        let forward: TimeInterval = 10
        let rollback: TimeInterval = 5
        let store = DiagnosticStore(storage: DiagnosticTestStorage()) { clock.now() }
        store.record(DiagnosticFixtures.event())
        let original = await store.snapshot()
        clock.advance(forward)
        _ = await store.snapshot()
        clock.advance(-rollback)
        store.record(DiagnosticFixtures.event(operation: .workspaceCreate))
        let fresh = await store.snapshot()
        #expect(fresh.historyRevision != original.historyRevision)
        #expect(fresh.metadata.retainedRecords == 2)
        guard case .ready(let report) = await store.prepareExport(reviewing: fresh) else {
            Issue.record("A new review must work before the clock reaches its former high-water mark")
            return
        }
        let entries = try DiagnosticZIPTestReader.extract(Data(contentsOf: report.archiveURL))
        #expect(entries["events.jsonl"] == fresh.jsonLines)
        #expect(await store.endReport(report))
    }

    @Test func clockObservationsAreCoherentAndDetectSubsecondRollback() async {
        let clock = DiagnosticTestClock()
        let forward: TimeInterval = 0.75
        let storage = DiagnosticTestStorage()
        let limits = DiagnosticLimits()
        let intake = DiagnosticIntake(limits: limits) { clock.now() }
        let writer = DiagnosticWriter(storage: storage, intake: intake, limits: limits) { clock.now() }
        let reviewed = await writer.snapshot()
        #expect(clock.readCount == 1)
        clock.advance(forward)
        guard case .ready(let report) = await writer.prepareExport(reviewing: reviewed) else {
            Issue.record("A valid export should use one clock observation before and after writing")
            return
        }
        #expect(clock.readCount == 3)
        #expect(await writer.endReport(report))
        clock.advance(-0.5)
        guard case .needsReview(let fresh) = await writer.prepareExport(reviewing: reviewed) else {
            Issue.record("Clock rollback within one encoded second must also invalidate the review")
            return
        }
        // One validation observation and one fresh snapshot/flush observation.
        #expect(clock.readCount == 5)
        #expect(fresh.metadata.generatedAt == reviewed.metadata.generatedAt)
        #expect(fresh.historyRevision != reviewed.historyRevision)
        guard case .ready(let freshReport) = await writer.prepareExport(reviewing: fresh) else {
            Issue.record("A stable clock after a subsecond rollback must allow a fresh review")
            return
        }
        #expect(clock.readCount == 7)
        #expect(await writer.endReport(freshReport))
    }

    @Test func anotherWindowClearInvalidatesReviewButPreservesActiveConsumer() async throws {
        let store = DiagnosticStore(storage: DiagnosticTestStorage())
        store.record(DiagnosticFixtures.event())
        let reviewed = await store.snapshot()
        let report = try #require(await store.beginReport())
        let original = try Data(contentsOf: report.archiveURL)
        #expect(await store.clearHistory())
        #expect(try Data(contentsOf: report.archiveURL) == original)
        guard case .needsReview(let updated) = await store.prepareExport(reviewing: reviewed) else {
            Issue.record("Clear must invalidate every window's old preview")
            return
        }
        #expect(updated.jsonLines.isEmpty)
        #expect(await store.endReport(report))
        #expect(!FileManager.default.fileExists(atPath: report.directory.path))
    }

    @Test func cancelledPreparationCreatesNoArchiveAndCanRepeat() async throws {
        let storage = DiagnosticTestStorage()
        let store = DiagnosticStore(storage: storage)
        let reviewed = await store.snapshot()
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await store.prepareExport(reviewing: reviewed)
        }
        guard case .unavailable = await operation.value else {
            Issue.record("Cancelled export must not create a share item")
            return
        }
        let report = try #require(await store.beginReport())
        #expect(await store.endReport(report))
    }

    @Test func failedPreparationCleansOwnedFilesAndAllowsRetry() async throws {
        let storage = DiagnosticTestStorage()
        let store = DiagnosticStore(storage: storage)
        let reviewed = await store.snapshot()
        storage.state.withLock { $0.failWrite = true }
        guard case .unavailable = await store.prepareExport(reviewing: reviewed) else {
            Issue.record("Expected storage preparation failure")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: storage.files.directory.appendingPathComponent("report").path))
        storage.state.withLock { $0.failWrite = false }
        let report = try #require(await store.beginReport())
        #expect(await store.endReport(report))
    }

    @Test func repeatExportNeverAccumulatesAndStaleCompletionCannotDeleteNewZIP() async throws {
        let storage = DiagnosticTestStorage()
        let store = DiagnosticStore(storage: storage)
        let repetitions = 5
        var previous: DiagnosticReport?
        for _ in 0..<repetitions {
            let report = try #require(await store.beginReport())
            let lease = DiagnosticShareLease(report: report, store: store)
            if let previous { #expect(!(await store.endReport(previous))) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: report.directory.path) == ["diagnostics.zip"])
            #expect(await store.beginReport() == nil)
            #expect(await lease.finish())
            #expect(await lease.finish())
            #expect(!FileManager.default.fileExists(atPath: report.directory.path))
            previous = report
        }
    }

    @Test func cleanupFailureDoesNotPermanentlyPinReport() async throws {
        let storage = DiagnosticTestStorage()
        let store = DiagnosticStore(storage: storage)
        let report = try #require(await store.beginReport())
        storage.state.withLock { $0.failClear = true }
        #expect(!(await store.endReport(report)))
        storage.state.withLock { $0.failClear = false }
        let next = try #require(await store.beginReport())
        #expect(!(await store.endReport(report)))
        #expect(await store.endReport(next))
    }

    @Test(arguments: [false, true])
    func cancellationOrFailureAfterWritingRemovesPartialReport(cancel: Bool) async throws {
        let storage = DiagnosticTestStorage()
        let store = DiagnosticStore(storage: storage)
        let reviewed = await store.snapshot()
        storage.state.withLock { state in
            state.afterReportWrite = {
                if cancel {
                    withUnsafeCurrentTask { $0?.cancel() }
                } else {
                    throw DiagnosticTestStorage.Failure.simulated
                }
            }
        }
        let task = Task { await store.prepareExport(reviewing: reviewed) }
        guard case .unavailable = await task.value else {
            Issue.record("A cancelled/failed write must not escape as a share item")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: storage.files.directory.appendingPathComponent("report").path))
        storage.state.withLock { $0.afterReportWrite = nil }
        let report = try #require(await store.beginReport())
        #expect(await store.endReport(report))
    }

    @Test func expiryDuringFilePreparationRemovesArchiveAndRequiresReview() async {
        let clock = DiagnosticTestClock()
        let storage = DiagnosticTestStorage()
        let store = DiagnosticStore(storage: storage) { clock.now() }
        store.record(DiagnosticFixtures.event())
        let reviewed = await store.snapshot()
        storage.state.withLock { state in
            state.afterReportWrite = { clock.advance(DiagnosticLimits.maximumAge) }
        }
        guard case .needsReview(let updated) = await store.prepareExport(reviewing: reviewed) else {
            Issue.record("Expiry during ZIP writing must invalidate that ZIP")
            return
        }
        #expect(updated.jsonLines.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: storage.files.directory.appendingPathComponent("report").path))
    }

    @Test(arguments: [-1.0, 5.0])
    func rollbackDuringFilePreparationRemovesArchiveAndAllowsFreshReview(offset: TimeInterval) async {
        let clock = DiagnosticTestClock()
        let forward: TimeInterval = 10
        let storage = DiagnosticTestStorage()
        let store = DiagnosticStore(storage: storage) { clock.now() }
        store.record(DiagnosticFixtures.event())
        let reviewed = await store.snapshot()
        clock.advance(forward)
        storage.state.withLock { state in
            state.afterReportWrite = { clock.advance(offset - forward) }
        }
        guard case .needsReview(let updated) = await store.prepareExport(reviewing: reviewed) else {
            Issue.record("Rollback during ZIP writing must invalidate the archive, including partial rollback")
            return
        }
        #expect(updated.historyRevision != reviewed.historyRevision)
        #expect(updated.metadata.generatedAt == reviewed.metadata.generatedAt.addingTimeInterval(offset))
        #expect(updated.jsonLines == (offset < 0 ? Data() : reviewed.jsonLines))
        #expect(!FileManager.default.fileExists(atPath: storage.files.directory.appendingPathComponent("report").path))
        storage.state.withLock { $0.afterReportWrite = nil }
        guard case .ready(let report) = await store.prepareExport(reviewing: updated) else {
            Issue.record("A fresh review must work immediately after rejecting the stale archive")
            return
        }
        #expect(await store.endReport(report))
        clock.advance(forward - offset)
        guard case .needsReview = await store.prepareExport(reviewing: reviewed) else {
            Issue.record("The invalidated preparation must stay invalid after clock recovery")
            return
        }
    }
}
