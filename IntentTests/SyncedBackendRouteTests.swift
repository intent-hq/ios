import Foundation
import Testing

@testable import Intent

struct SyncedBackendRouteTests {
    private func record(tcAddress: Any? = nil, host: String = "mac.local") throws -> SyncedBackendRecord {
        var payload: [String: Any] = [
            "v": 1, "label": "Mac", "host": host, "hosts": [], "port": 8843,
            "fingerprint": "aa:bb", "token": "secret", "updatedAt": 200
        ]
        payload["tcAddress"] = tcAddress
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = try #require(String(data: data, encoding: .utf8))
        guard case .record(let record) = SyncedBackendPayload.parse(text) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return record
    }

    @Test func importsTailcatRouteWithoutChangingCase() throws {
        let remote = try record(tcAddress: "tcMiXeD_Case-Address")
        let result = SyncedBackendConnectionMerge.merge(records: [remote], into: [])
        let added = try #require(result.connections.first)
        #expect(added.server.tcAddress == "tcMiXeD_Case-Address")
        #expect(added.server.hosts == ["mac.local"])
        #expect(added.token == "secret")
    }

    @Test func importsTunnelOnlyBackendWithoutUsableLANHost() throws {
        let remote = try record(tcAddress: "tcMiXeD_Case-Address", host: "unusable/host")
        let result = SyncedBackendConnectionMerge.merge(records: [remote], into: [])
        let added = try #require(result.connections.first)
        #expect(added.server.hosts.isEmpty)
        #expect(added.server.tcAddress == "tcMiXeD_Case-Address")
    }

    @Test func newerRouteReplacesLocallyLearnedAddress() throws {
        let remote = try record(tcAddress: "tcNewMiXeD")
        let existing = SyncedBackendConnectionMergeTests().local(syncUpdatedAt: 100, tcAddress: "tcOld")
        let result = SyncedBackendConnectionMerge.merge(records: [remote], into: [existing])
        #expect(result.updatedIds == [existing.id])
        #expect(result.connections.first?.server.tcAddress == "tcNewMiXeD")
    }

    @Test func absentNullEmptyAndMalformedValuesPreserveKnownRoute() throws {
        let values: [Any?] = [nil, NSNull(), "", " \n", 42, true, ["address": "tcOther"]]
        let existing = SyncedBackendConnectionMergeTests().local(syncUpdatedAt: 100, tcAddress: "tcKnown")
        for value in values {
            let remote = try record(tcAddress: value)
            let result = SyncedBackendConnectionMerge.merge(records: [remote], into: [existing])
            #expect(result.updatedIds == [existing.id])
            #expect(result.connections.first?.server.tcAddress == "tcKnown")
            #expect(result.connections.first?.token == "secret")
        }
    }

    @Test func olderRouteDoesNotReplaceKnownRoute() throws {
        let remote = try record(tcAddress: "tcOld")
        let existing = SyncedBackendConnectionMergeTests().local(syncUpdatedAt: 300, tcAddress: "tcKnown")
        let result = SyncedBackendConnectionMerge.merge(records: [remote], into: [existing])
        #expect(!result.changed)
        #expect(result.connections.first?.server.tcAddress == "tcKnown")
    }

    @Test func equalClockUpgradeLearnsOnlyMissingRoute() throws {
        let remote = try record(tcAddress: "tcUpgradeMiXeD")
        let existing = SyncedBackendConnectionMergeTests().local(syncUpdatedAt: 200)
        let result = SyncedBackendConnectionMerge.merge(records: [remote], into: [existing])
        let updated = try #require(result.connections.first)
        #expect(result.updatedIds == [existing.id])
        #expect(updated.server.tcAddress == "tcUpgradeMiXeD")
        #expect(updated.server.hosts == existing.server.hosts)
        #expect(updated.token == existing.token)
        #expect(updated.displayName == existing.displayName)
        #expect(updated.syncUpdatedAt == 200)
        #expect(updated.pendingSyncUpdatedAt == nil)
        #expect(!SyncedBackendConnectionMerge.merge(records: [remote], into: result.connections).changed)
    }

    @Test func equalClockDoesNotReplaceKnownRouteOrEnrichPendingPairing() throws {
        let remote = try record(tcAddress: "tcRemote")
        let existing = SyncedBackendConnectionMergeTests().local(syncUpdatedAt: 200, tcAddress: "tcKnown")
        #expect(!SyncedBackendConnectionMerge.merge(records: [remote], into: [existing]).changed)
        var pending = SyncedBackendConnectionMergeTests().local(syncUpdatedAt: 200)
        pending.pendingSyncUpdatedAt = 300
        #expect(!SyncedBackendConnectionMerge.merge(records: [remote], into: [pending]).changed)
    }
}
