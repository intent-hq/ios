import Foundation
@testable import Intent
import Testing

struct DiagnosticStoreTests {
    @Test func emptyHistoryAndMetadataAreSafe() async throws {
        let storage = DiagnosticTestStorage()
        let store = DiagnosticStore(storage: storage)
        let snapshot = await store.snapshot()
        #expect(snapshot.jsonLines.isEmpty)
        #expect(snapshot.metadata.retainedRecords == 0)
        #expect(snapshot.metadata.pendingFamilies == DiagnosticCoverage.pendingFamilies)
        #expect(snapshot.metadata.coverageVersion == DiagnosticCoverage.version)
        #expect(!snapshot.metadata.loss.storageUnavailable)
        let metadata = try snapshot.metadataJSON()
        #expect(!metadata.isEmpty)
    }

    @Test func identicalFailuresRetainCountAndFirstLastAcrossFlushes() async throws {
        let clock = DiagnosticTestClock()
        let store = DiagnosticStore(storage: DiagnosticTestStorage()) { clock.now() }
        let first = clock.now()
        store.record(DiagnosticFixtures.event())
        _ = await store.snapshot()
        clock.advance(2)
        store.record(DiagnosticFixtures.event())
        clock.advance(2)
        store.record(DiagnosticFixtures.event())
        let records = try DiagnosticFixtures.records(await store.snapshot())
        #expect(records.count == 1)
        #expect(records.first?.count == 3)
        #expect(records.first?.firstTimestamp == first)
        #expect(records.first?.lastTimestamp == clock.now())
    }

    @Test func differentOperationsStagesFailuresScopesAndRecoveryStaySeparate() async throws {
        let store = DiagnosticStore(storage: DiagnosticTestStorage())
        let scope = store.makeScope()
        store.record(DiagnosticFixtures.event(), scope: scope)
        store.record(DiagnosticFixtures.event(operation: .workspaceCreate), scope: scope)
        store.record(DiagnosticFixtures.event(stage: .decode), scope: scope)
        store.record(DiagnosticFixtures.event(failure: .remoteRPC(code: -2)), scope: scope)
        store.record(DiagnosticFixtures.event(), scope: store.makeScope())
        store.record(DiagnosticFixtures.event(outcome: .recovered), scope: scope)
        store.record(DiagnosticFixtures.event(outcome: .recovered), scope: scope)
        store.record(DiagnosticFixtures.event(outcome: .exhausted), scope: scope)
        store.record(DiagnosticFixtures.event(), scope: scope)
        let records = try DiagnosticFixtures.records(await store.snapshot())
        #expect(records.count == 9)
        #expect(records.allSatisfy { $0.count == 1 })
        #expect(records.map(\.sequence) == Array(1...9).map(UInt64.init))
    }

    @Test func reopensHistoryButNeverMergesAcrossLaunches() async throws {
        let storage = DiagnosticTestStorage()
        let first = DiagnosticStore(storage: storage)
        first.record(DiagnosticFixtures.event())
        let previous = try DiagnosticFixtures.records(await first.snapshot())
        let second = DiagnosticStore(storage: storage)
        second.record(DiagnosticFixtures.event())
        let records = try DiagnosticFixtures.records(await second.snapshot())
        #expect(records.count == 2)
        #expect(records.first == previous.first)
        #expect(records.first?.session != records.last?.session)
        #expect(records.allSatisfy { $0.sequence == 1 })
    }

    @Test func retentionExpiresOnAppendSnapshotAndReopen() async throws {
        let storage = DiagnosticTestStorage()
        let clock = DiagnosticTestClock()
        let store = DiagnosticStore(storage: storage) { clock.now() }
        store.record(DiagnosticFixtures.event())
        _ = await store.snapshot()
        clock.advance(DiagnosticLimits.maximumAge)
        store.record(DiagnosticFixtures.event(operation: .workspaceCreate))
        let snapshot = await store.snapshot()
        #expect(try DiagnosticFixtures.records(snapshot).map(\.event.operation) == [.workspaceCreate])
        #expect(snapshot.metadata.loss.expiredRecords == 1)
        clock.advance(DiagnosticLimits.maximumAge)
        let reopened = DiagnosticStore(storage: storage) { clock.now() }
        #expect(await reopened.snapshot().jsonLines.isEmpty)
        reopened.record(DiagnosticFixtures.event())
        _ = await reopened.snapshot()
        clock.advance(DiagnosticLimits.maximumAge)
        #expect(await reopened.snapshot().jsonLines.isEmpty)
    }

    @Test func summaryUsesFirstTimestampForConservativeExpiry() async throws {
        let clock = DiagnosticTestClock()
        let store = DiagnosticStore(storage: DiagnosticTestStorage()) { clock.now() }
        store.record(DiagnosticFixtures.event())
        _ = await store.snapshot()
        clock.advance(DiagnosticLimits.maximumAge - 1)
        store.record(DiagnosticFixtures.event())
        #expect(try DiagnosticFixtures.records(await store.snapshot()).first?.count == 2)
        clock.advance(1)
        #expect(await store.snapshot().jsonLines.isEmpty)
        store.record(DiagnosticFixtures.event())
        #expect(try DiagnosticFixtures.records(await store.snapshot()).first?.count == 1)
    }

    @Test func clockRollbackCannotKeepFutureEvents() async {
        let clock = DiagnosticTestClock()
        let store = DiagnosticStore(storage: DiagnosticTestStorage()) { clock.now() }
        store.record(DiagnosticFixtures.event())
        _ = await store.snapshot()
        clock.advance(-1)
        let snapshot = await store.snapshot()
        #expect(snapshot.jsonLines.isEmpty)
        #expect(snapshot.metadata.loss.expiredRecords == 1)
    }

    @Test func byteRotationKeepsNewestWholeRecordsOnDiskAndInExport() async throws {
        let storage = DiagnosticTestStorage()
        let limits = DiagnosticLimits(historyBytes: 2048)
        let store = DiagnosticStore(storage: storage, limits: limits)
        for _ in 0..<20 {
            store.record(DiagnosticFixtures.event(), scope: store.makeScope())
        }
        let snapshot = await store.snapshot()
        let records = try DiagnosticFixtures.records(snapshot)
        #expect(snapshot.jsonLines.count <= limits.historyBytes)
        #expect(records.last?.sequence == 20)
        #expect(snapshot.metadata.loss.rotatedRecords > 0)
        let disk = try storage.files.readHistory(maximumBytes: limits.historyBytes)
        #expect(disk == snapshot.jsonLines)
    }

    @Test func clearAlsoRemovesReportsAndStaleLeaseCannotDeleteNewReport() async throws {
        let storage = DiagnosticTestStorage()
        let store = DiagnosticStore(storage: storage)
        store.record(DiagnosticFixtures.event())
        let oldReport = try #require(await store.beginReport())
        #expect(await store.clearHistory())
        #expect(!FileManager.default.fileExists(atPath: oldReport.directory.path))
        #expect(await store.snapshot().jsonLines.isEmpty)
        let newReport = try #require(await store.beginReport())
        #expect(!(await store.endReport(oldReport)))
        #expect(FileManager.default.fileExists(atPath: newReport.directory.path))
        #expect(await store.endReport(newReport))
    }

    @Test func reportsHaveFixedSafeEntriesAndStayPinnedUntilDismissal() async throws {
        let clock = DiagnosticTestClock()
        let storage = DiagnosticTestStorage()
        let store = DiagnosticStore(storage: storage) { clock.now() }
        store.record(DiagnosticFixtures.event())
        let report = try #require(await store.beginReport())
        let files = try FileManager.default.contentsOfDirectory(atPath: report.directory.path)
        #expect(Set(files) == ["events.jsonl", "metadata.json"])
        #expect(await store.beginReport() == nil)
        clock.advance(DiagnosticLimits.maximumAge)
        _ = await store.snapshot()
        #expect(try Data(contentsOf: report.directory.appendingPathComponent("events.jsonl")) == report.snapshot.jsonLines)
        #expect(await store.endReport(report))
        #expect(!FileManager.default.fileExists(atPath: report.directory.path))
    }

    @Test func relaunchCleansAbandonedReports() async throws {
        let storage = DiagnosticTestStorage()
        let store = DiagnosticStore(storage: storage)
        let report = try #require(await store.beginReport())
        let reopened = DiagnosticStore(storage: storage)
        _ = await reopened.snapshot()
        #expect(!FileManager.default.fileExists(atPath: report.directory.path))
    }
}
