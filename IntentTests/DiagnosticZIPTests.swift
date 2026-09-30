import Foundation
@testable import Intent
import Synchronization
import Testing

struct DiagnosticZIPTests {
    @Test func archiveReopensWithExactReviewedEntriesAndNoUnrelatedFiles() async throws {
        let storage = DiagnosticTestStorage()
        let store = DiagnosticStore(storage: storage)
        store.record(DiagnosticFixtures.event())
        let reviewed = await store.snapshot()
        let unrelated = storage.files.directory.appendingPathComponent("unrelated.txt")
        let sentinel = Data("synthetic-unrelated-content".utf8)
        try sentinel.write(to: unrelated)
        let report = try #require(await store.beginReport())
        let archive = try Data(contentsOf: report.archiveURL)
        let entries = try DiagnosticZIPTestReader.extract(archive)
        #expect(entries["events.jsonl"] == reviewed.jsonLines)
        #expect(entries["metadata.json"] == (try report.snapshot.metadataJSON()))
        #expect(archive.count <= DiagnosticZIP.maximumArchiveBytes)
        #expect(!archive.contains(sentinel))
        #expect(!storage.state.withLock { $0.touchedMainThread })
        #expect(await store.endReport(report))
        #expect(try Data(contentsOf: unrelated) == sentinel)
    }

    @Test func emptyHistoryStillProducesValidTwoEntryZIP() async throws {
        let store = DiagnosticStore(storage: DiagnosticTestStorage())
        let report = try #require(await store.beginReport())
        let entries = try DiagnosticZIPTestReader.extract(Data(contentsOf: report.archiveURL))
        #expect(entries["events.jsonl"] == Data())
        let metadata = try #require(entries["metadata.json"])
        let object = try #require(JSONSerialization.jsonObject(with: metadata) as? [String: Any])
        #expect(object["retainedRecords"] as? Int == 0)
        #expect(object["retentionHours"] as? Int == 48)
        #expect(object["maximumHistoryBytes"] as? Int == DiagnosticLimits.maximumHistoryBytes)
        #expect(object["pendingFamilies"] as? [String] == DiagnosticCoverage.pendingFamilies.map(\.rawValue))
        #expect(object["historyRevision"] == nil)
        #expect(object["expiresAt"] == nil)
        #expect(await store.endReport(report))
    }

    @Test func maximumPayloadIsBoundedAndOversizedPayloadIsRejected() async throws {
        let snapshot = await DiagnosticStore(storage: DiagnosticTestStorage()).snapshot()
        let maximum = DiagnosticSnapshot(
            jsonLines: Data(repeating: 0, count: DiagnosticLimits.maximumHistoryBytes),
            metadata: snapshot.metadata,
            historyRevision: snapshot.historyRevision,
            expiresAt: snapshot.expiresAt
        )
        let archive = try DiagnosticZIP.encode(maximum)
        #expect(archive.count <= DiagnosticZIP.maximumArchiveBytes)
        #expect(try DiagnosticZIPTestReader.extract(archive)["events.jsonl"] == maximum.jsonLines)
        let oversized = DiagnosticSnapshot(
            jsonLines: Data(repeating: 0, count: DiagnosticLimits.maximumHistoryBytes + 1),
            metadata: snapshot.metadata,
            historyRevision: snapshot.historyRevision,
            expiresAt: snapshot.expiresAt
        )
        #expect(throws: DiagnosticZIP.Failure.self) { try DiagnosticZIP.encode(oversized) }
    }
}
