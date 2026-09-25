import Foundation
import Testing

@testable import Intent

struct BackendKeychainConformanceTests {
    private typealias Fixtures = BackendKeychainFixtures
    private typealias Support = BackendKeychainConformanceSupport

    @Test func parsesAndListsEveryCanonicalCase() throws {
        let fixtures = try Fixtures.bundled()
        #expect(SyncedBackendRegistry.service == fixtures.corpus["service"] as? String)
        for fixture in try fixtures.cases("parseCases") {
            let id: String = try Fixtures.value("id", in: fixture)
            let payload: String = try Fixtures.value("payload", in: fixture)
            let expected: Fixtures.Object = try Fixtures.value("ios", in: fixture)
            let actual: Fixtures.Object
            switch SyncedBackendPayload.parse(payload) {
            case .invalid: actual = ["kind": "invalid"]
            case .newerVersion: actual = ["kind": "newer-version"]
            case .record(let record): actual = ["kind": "record", "record": Support.record(record)]
            }
            try Support.expectJSON(actual, expected, id: id)
            let cloud = MemorySyncedKeychain()
            cloud.items[id] = Data(payload.utf8)
            let registry = SyncedBackendRegistry(keychain: cloud, accessGroup: BackendSyncFixtures.accessGroup)
            let records = try listed(registry.listBackends(now: Support.date(0)))
            let expectedRecords = (expected["record"] as? Fixtures.Object).map { [$0] } ?? []
            try Support.expectJSON(records.map(Support.record), expectedRecords, id: id)
            #expect(cloud.writeCount == 0, "\(id)")
        }
    }

    @Test func normalizesCanonicalIdentityKeys() throws {
        for fixture in try Fixtures.bundled().cases("identityCases") {
            let id: String = try Fixtures.value("id", in: fixture)
            let record = try SyncedBackendRecord(
                label: "", host: Fixtures.value("host", in: fixture), hosts: [],
                port: Fixtures.value("port", in: fixture), fingerprint: Fixtures.value("fingerprint", in: fixture),
                hostname: nil, detectHosts: true, token: "", updatedAt: 0, deleted: false, deletedAt: nil
            )
            #expect(record.accountKey == fixture["accountKey"] as? String, "\(id)")
            #expect(record.registryKey == fixture["registryKey"] as? String, "\(id)")
        }
    }

    @Test func expiresTombstonesAtCanonicalBoundaries() throws {
        let fixtures = try Fixtures.bundled()
        #expect(SyncedBackendRecord.tombstoneTTLMs == fixtures.corpus["tombstoneTtlMs"] as? Double)
        for fixture in try fixtures.cases("expiryCases") {
            let id: String = try Fixtures.value("id", in: fixture)
            let parseCase = try fixtures.parseCase(Fixtures.value("parseCaseId", in: fixture))
            let payload: String = try Fixtures.value("payload", in: parseCase)
            let record = try parsed(payload)
            let now = try Support.date(Fixtures.value("nowMs", in: fixture))
            let expired: Bool = try Fixtures.value("expired", in: fixture)
            #expect(record.isExpiredTombstone(now: now) == expired, "\(id)")
            let cloud = MemorySyncedKeychain()
            cloud.items[id] = Data(payload.utf8)
            let registry = SyncedBackendRegistry(keychain: cloud, accessGroup: BackendSyncFixtures.accessGroup)
            let expectedParse: Fixtures.Object = try Fixtures.value("ios", in: parseCase)
            let expectedRecord: Fixtures.Object = try Fixtures.value("record", in: expectedParse)
            let records = try listed(registry.listBackends(now: now))
            try Support.expectJSON(records.map(Support.record), expired ? [] : [expectedRecord], id: id)
            let live = try listed(registry.listLiveBackends(now: now))
            let deleted: Bool = try Fixtures.value("deleted", in: expectedRecord)
            try Support.expectJSON(live.map(Support.record), expired || deleted ? [] : [expectedRecord], id: id)
        }
    }

    @Test func publishesCanonicalPayloadsAndPreservesMetadata() throws {
        for fixture in try Fixtures.bundled().cases("iosPublishCases") {
            let id: String = try Fixtures.value("id", in: fixture)
            let cloud = MemorySyncedKeychain()
            let existing: [Fixtures.Object] = try Fixtures.value("existing", in: fixture)
            for row in existing {
                try cloud.put(Fixtures.value("payload", in: row), account: Fixtures.value("account", in: row))
            }
            let connection = try Support.connection(Fixtures.value("connection", in: fixture))
            let publisher = BackendSyncFixtures.publisher(cloud)
            let outcome: SyncedBackendPublisher.Outcome
            switch fixture["operation"] as? String {
            case "pair": outcome = publisher.publish(connection)
            case "routes": outcome = publisher.publishRoutes(connection)
            default: throw BackendKeychainFixtureError.invalid("unknown publication operation in \(id)")
            }
            let expected: Fixtures.Object = try Fixtures.value("expected", in: fixture)
            try Support.expectJSON(
                ["outcome": Support.outcome(outcome), "writes": try Support.writes(cloud)], expected, id: id
            )
            let expectedWrites: [Fixtures.Object] = try Fixtures.value("writes", in: expected)
            #expect(cloud.writeCount == expectedWrites.count, "\(id)")
            for write in expectedWrites {
                let payload: Fixtures.Object = try Fixtures.value("payload", in: write)
                try Support.expectJSON(cloud.object(account: Fixtures.value("account", in: write)), payload, id: id)
            }
        }
    }

    @Test func importsCanonicalRoutesAndIdentity() throws {
        let fixtures = try Fixtures.bundled()
        for fixture in try fixtures.cases("iosImportCases") {
            let id: String = try Fixtures.value("id", in: fixture)
            let parseCase = try fixtures.parseCase(Fixtures.value("parseCaseId", in: fixture))
            let cloud = MemorySyncedKeychain()
            let payload: String = try Fixtures.value("payload", in: parseCase)
            cloud.items[id] = Data(payload.utf8)
            let registry = SyncedBackendRegistry(keychain: cloud, accessGroup: BackendSyncFixtures.accessGroup)
            let records = try listed(registry.listBackends(now: Support.date(0)))
            let result = SyncedBackendConnectionMerge.merge(records: records, into: [], now: Support.date(0))
            #expect(result.connections.count == 1, "\(id)")
            let connection = try #require(result.connections.first)
            let actual: Fixtures.Object = [
                "hosts": connection.server.hosts, "port": connection.server.port,
                "fingerprint": connection.server.certFingerprint as Any? ?? NSNull(), "token": connection.token,
                "tcAddress": connection.server.tcAddress as Any? ?? NSNull()
            ]
            let expected: Fixtures.Object = try Fixtures.value("expected", in: fixture)
            try Support.expectJSON(actual, expected, id: id)
            #expect(result.addedIds == [connection.id], "\(id)")
            #expect(result.updatedIds.isEmpty && result.removedIds.isEmpty, "\(id)")
        }
    }

    @Test func freezesCanonicalInvalidAndFuturePayloads() throws {
        let fixtures = try Fixtures.bundled()
        for fixture in try fixtures.cases("noWriteCases") {
            let id: String = try Fixtures.value("id", in: fixture)
            let parseCase = try fixtures.parseCase(Fixtures.value("parseCaseId", in: fixture))
            let cloud = MemorySyncedKeychain()
            let account: String = try Fixtures.value("account", in: fixture)
            let payload: String = try Fixtures.value("payload", in: parseCase)
            cloud.items[account] = Data(payload.utf8)
            let before = cloud.items
            let connection = try Support.connection(Fixtures.value("connection", in: fixture))
            let now: Double = try Fixtures.value("nowMs", in: fixture)
            let outcome = BackendSyncFixtures.publisher(cloud, clock: now).publish(connection)
            let expected: Fixtures.Object = try Fixtures.value("expected", in: fixture)
            let expectedIOS: Fixtures.Object = try Fixtures.value("ios", in: expected)
            try Support.expectJSON(
                ["outcome": Support.outcome(outcome), "writes": try Support.writes(cloud)], expectedIOS, id: id
            )
            #expect(cloud.items == before, "\(id): original bytes must survive")
            #expect(cloud.writeCount == 0, "\(id)")
            let registry = SyncedBackendRegistry(keychain: cloud, accessGroup: BackendSyncFixtures.accessGroup)
            let records = try listed(registry.listBackends(now: Support.date(now)))
            #expect(records.isEmpty, "\(id)")
            let merged = SyncedBackendConnectionMerge.merge(records: records, into: [connection])
            #expect(!merged.changed && merged.connections == [connection], "\(id): pending pairing survives")
        }
    }

    private func parsed(_ payload: String) throws -> SyncedBackendRecord {
        guard case .record(let record) = SyncedBackendPayload.parse(payload) else {
            throw BackendKeychainFixtureError.invalid("expected a production record")
        }
        return record
    }

    private func listed(_ result: SyncedBackendRegistryList) throws -> [SyncedBackendRecord] {
        guard case .available(let records) = result else {
            throw BackendKeychainFixtureError.invalid("fake registry is unexpectedly unavailable")
        }
        return records
    }
}
