import Foundation
@testable import Intent
import Testing

struct DiagnosticExportTests {
    @Test func exportsReviewedSnapshotNotEventsArrivingAfterReview() async throws {
        let store = DiagnosticStore(storage: DiagnosticTestStorage())
        store.record(DiagnosticFixtures.event())
        let reviewed = await store.snapshot()
        store.record(DiagnosticFixtures.event(operation: .workspaceCreate))
        guard case .ready(let report) = await store.prepareExport(reviewing: reviewed) else {
            Issue.record("Expected a report for the reviewed snapshot")
            return
        }
        let entries = try DiagnosticZIPTestReader.extract(Data(contentsOf: report.archiveURL))
        #expect(entries["events.jsonl"] == reviewed.jsonLines)
        #expect(entries["metadata.json"] == (try reviewed.metadataJSON()))
        #expect(await store.endReport(report))
    }

    @Test(arguments: [false, true])
    func expiryAndClockRollbackRequireAnotherReview(rollback: Bool) async throws {
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
}