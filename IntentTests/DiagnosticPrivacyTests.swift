import Foundation
@testable import Intent
import Security
import Testing

struct DiagnosticPrivacyTests {
    @Test func allEventKindsAndFailureClassesRoundTripWithinRecordBound() throws {
        for kind in DiagnosticEvent.Kind.allCases {
            for classification in DiagnosticFailure.Classification.allCases {
                let event = DiagnosticEvent(
                    kind: kind,
                    operation: .otherLocalOperation,
                    site: .appCoordinator,
                    stage: .active,
                    outcome: .failed,
                    failure: DiagnosticFailure(origin: .localOperation, classification: classification)
                )
                let data = try DiagnosticEncoding.encoder().encode(event)
                #expect(data.count < DiagnosticLimits.maximumRecordBytes)
                #expect(try DiagnosticEncoding.decoder().decode(DiagnosticEvent.self, from: data) == event)
            }
        }
    }

    @Test func foreignCodeCannotMasqueradeAsLocalTimeout() {
        let remote = DiagnosticFailure.remoteRPC(code: -2)
        #expect(remote.origin == .remoteRPC)
        #expect(remote.classification == .remoteRejected)
        #expect(remote.code == .other)
        #expect(remote != DiagnosticFailure(origin: .localRequest, classification: .requestTimeout))
        let invalidParameters = -32_602
        #expect(DiagnosticFailure.remoteRPC(code: invalidParameters).code == .invalidParameters)
        #expect(DiagnosticFailure.securityStatus(errSecAuthFailed, classification: .readFailed).code == .authentication)
        #expect(DiagnosticFailure.securityStatus(Int32.max, classification: .readFailed).code == .other)
    }

    @Test func everyOperationSerializesOnlyClosedFields() async throws {
        let store = DiagnosticStore(storage: DiagnosticTestStorage())
        for operation in DiagnosticOperation.allCases { store.record(DiagnosticFixtures.event(operation: operation)) }
        let snapshot = await store.snapshot()
        let records = try DiagnosticFixtures.records(snapshot)
        #expect(records.count == DiagnosticOperation.allCases.count)
        #expect(Set(records.map(\.event.operation)) == Set(DiagnosticOperation.allCases))
        let allowedKeys: Set<String> = [
            "schemaVersion", "session", "sequence", "event", "count", "firstTimestamp", "lastTimestamp"
        ]
        for line in snapshot.jsonLines.split(separator: DiagnosticEncoding.newline) {
            let value = try #require(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
            #expect(Set(value.keys) == allowedKeys)
            let event = try #require(value["event"] as? [String: Any])
            #expect(Set(event.keys) == ["kind", "operation", "site", "stage", "outcome", "failure", "effect", "context"])
            let failure = try #require(event["failure"] as? [String: Any])
            #expect(Set(failure.keys) == ["origin", "classification", "code"])
        }
    }

    @Test func unknownFieldsNeverSurviveReopenOrExportAndMalformedTailIsDiscarded() async throws {
        let storage = DiagnosticTestStorage()
        let store = DiagnosticStore(storage: storage)
        store.record(DiagnosticFixtures.event())
        let initial = await store.snapshot()
        var object = try #require(JSONSerialization.jsonObject(with: Data(initial.jsonLines.dropLast())) as? [String: Any])
        let sentinels = ["Bearer synthetic-private-value", "https://private.example/secret", "/private/content.txt", "workspace-secret-id", "fingerprint-secret"]
        object["message"] = sentinels.joined(separator: " ")
        object["userInfo"] = ["token": sentinels[0]]
        var poisoned = try JSONSerialization.data(withJSONObject: object)
        poisoned.append(DiagnosticEncoding.newline)
        poisoned.append(Data("{\"incomplete\":\"private-tail".utf8))
        try storage.files.replaceHistory(poisoned)
        let reopened = DiagnosticStore(storage: storage)
        let snapshot = await reopened.snapshot()
        #expect(snapshot.metadata.loss.malformedRecords == 1)
        #expect(try DiagnosticFixtures.records(snapshot).count == 1)
        let report = try #require(await reopened.beginReport())
        let persisted = try storage.files.readHistory(maximumBytes: DiagnosticLimits.maximumHistoryBytes)
        let entries = try DiagnosticZIPTestReader.extract(Data(contentsOf: report.archiveURL))
        let exported = try #require(entries["events.jsonl"])
        for data in [persisted, exported, snapshot.jsonLines, try snapshot.metadataJSON()] {
            let text = try #require(String(data: data, encoding: .utf8))
            for sentinel in sentinels { #expect(!text.contains(sentinel)) }
            #expect(!text.contains("private-tail"))
        }
        #expect(await reopened.endReport(report))
    }

    @Test func unapprovedEnumValuesAndFutureSchemaAreRejected() async throws {
        let storage = DiagnosticTestStorage()
        let store = DiagnosticStore(storage: storage)
        store.record(DiagnosticFixtures.event())
        let initial = await store.snapshot()
        let original = try #require(String(data: initial.jsonLines, encoding: .utf8))
        let forgedEvent = original.replacingOccurrences(of: "workspace.load", with: "/private/user-file")
        let futureSchema = original.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":999")
        try storage.files.replaceHistory(Data((forgedEvent + futureSchema).utf8))
        let reopened = DiagnosticStore(storage: storage)
        let snapshot = await reopened.snapshot()
        #expect(snapshot.jsonLines.isEmpty)
        #expect(snapshot.metadata.loss.malformedRecords == 2)
    }

    @Test func oversizedHistoryResetsWithoutReadingUnboundedData() async throws {
        let storage = DiagnosticTestStorage()
        try storage.files.prepare()
        let byteLimit = 2048
        try storage.files.replaceHistory(Data(repeating: 65, count: byteLimit + 1))
        let store = DiagnosticStore(storage: storage, limits: DiagnosticLimits(historyBytes: byteLimit))
        let snapshot = await store.snapshot()
        #expect(snapshot.jsonLines.isEmpty)
        #expect(snapshot.metadata.loss.historyReset)
        #expect(try storage.files.readHistory(maximumBytes: byteLimit).isEmpty)
    }

    @Test func backupExclusionAppliesToHistoryAndReports() async throws {
        let storage = DiagnosticTestStorage()
        let store = DiagnosticStore(storage: storage)
        store.record(DiagnosticFixtures.event())
        let report = try #require(await store.beginReport())
        for url in reportFiles(storage: storage, report: report) {
            #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        }
        #expect(await store.endReport(report))
    }

    #if targetEnvironment(simulator)
    @Test(.disabled("Simulator does not expose Data Protection attributes; run on a physical device."))
    #else
    @Test
    #endif
    func fileProtectionAppliesToHistoryAndReportsOnDevice() async throws {
        let storage = DiagnosticTestStorage()
        let store = DiagnosticStore(storage: storage)
        store.record(DiagnosticFixtures.event())
        let report = try #require(await store.beginReport())
        for url in reportFiles(storage: storage, report: report) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let protection = (attributes[.protectionKey] as? FileProtectionType)?.rawValue
                ?? (attributes[.protectionKey] as? String)
            #expect(protection == FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
        }
        #expect(await store.endReport(report))
    }

    @Test func symlinkHistoryCannotReadOrOverwriteUnrelatedContent() async throws {
        let storage = DiagnosticTestStorage()
        try storage.files.prepare()
        let unrelated = storage.files.directory.appendingPathComponent("unrelated.txt")
        let content = Data("synthetic-private-content".utf8)
        try content.write(to: unrelated)
        try FileManager.default.createSymbolicLink(
            at: storage.files.directory.appendingPathComponent("events.jsonl"),
            withDestinationURL: unrelated
        )
        let store = DiagnosticStore(storage: storage)
        let snapshot = await store.snapshot()
        #expect(snapshot.jsonLines.isEmpty)
        #expect(snapshot.metadata.loss.storageUnavailable)
        #expect(try Data(contentsOf: unrelated) == content)
        #expect(await store.clearHistory())
        #expect(try Data(contentsOf: unrelated) == content)
    }

    private func reportFiles(storage: DiagnosticTestStorage, report: DiagnosticReport) -> [URL] {
        [
            storage.files.directory, storage.files.directory.appendingPathComponent("events.jsonl"),
            report.directory, report.archiveURL
        ]
    }
}
