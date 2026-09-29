import Foundation
import Security
import Testing

@testable import Intent

struct SyncedBackendPublisherTests {
    private func expectSuperseded(_ outcome: SyncedBackendPublisher.Outcome, sourceLocation: SourceLocation = #_sourceLocation) {
        guard case .superseded = outcome else {
            Issue.record("Expected a superseded publication, got \(outcome)", sourceLocation: sourceLocation)
            return
        }
    }

    @Test func writesDesktopV1PayloadToSynchronizableSharedGroup() throws {
        let cloud = MemorySyncedKeychain()
        let publisher = BackendSyncFixtures.publisher(cloud)
        #expect(publisher.publish(BackendSyncFixtures.local()) == .published)
        let attributes = try #require(cloud.adds.first)
        #expect(attributes[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(attributes[kSecAttrService as String] as? String == "com.cloudlands.intent.backends")
        #expect(attributes[kSecAttrAccessGroup as String] as? String == BackendSyncFixtures.accessGroup)
        #expect(attributes[kSecAttrAccount as String] as? String == "mac.local:8843")
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == true)
        #expect(attributes[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlock as String)
        let object = try cloud.object()
        #expect(object["v"] as? Int == 1)
        #expect(object["label"] as? String == "My Mac")
        #expect(object["fingerprint"] as? String == "aa:bb")
        #expect(object["token"] as? String == "local-token")
        #expect(object["tcAddress"] as? String == BackendSyncFixtures.route)
        #expect(object["hosts"] as? [String] == ["Mac.Local"])
        #expect(object["hostname"] is NSNull)
        #expect(object["detectHosts"] as? Bool == true)
        #expect(object["updatedAt"] as? Double == 1000)
        #expect(object["deleted"] == nil)
    }

    @Test func repairPreservesRawDesktopAndUnknownMetadata() throws {
        let cloud = MemorySyncedKeychain()
        let original = BackendSyncFixtures.remote()
        try cloud.put(original)
        #expect(BackendSyncFixtures.publisher(cloud).publish(BackendSyncFixtures.local()) == .published)
        let object = try cloud.object()
        for key in ["hostname", "detectHosts", "accent", "deviceIcon", "detectedDeviceKind", "futureMetadata"] {
            let beforeValue = try #require(original[key])
            let afterValue = try #require(object[key])
            let before = try JSONSerialization.data(withJSONObject: [key: beforeValue], options: [.sortedKeys])
            let after = try JSONSerialization.data(withJSONObject: [key: afterValue], options: [.sortedKeys])
            #expect(before == after)
        }
        #expect(object["token"] as? String == "local-token")
        #expect(object["deletedAt"] == nil)
        #expect(object["hosts"] as? [String] == ["Mac.Local", "10.0.0.1"])
        #expect(cloud.adds.isEmpty)
        #expect(cloud.updates.count == 1)
    }

    @Test func missingLocalRoutePreservesSharedRouteOnRepair() throws {
        let cloud = MemorySyncedKeychain()
        try cloud.put(BackendSyncFixtures.remote())
        var local = SyncedBackendConnectionMergeTests().local(hosts: ["mac.local"], token: "repaired")
        local.principal = .demoOwner
        local.pendingSyncUpdatedAt = 1000
        #expect(BackendSyncFixtures.publisher(cloud).publish(local) == .published)
        #expect(try cloud.object()["tcAddress"] as? String == "tcDesktop")
    }

    @Test func changedHostsMatchByFingerprintAndKeepExistingAccount() throws {
        let cloud = MemorySyncedKeychain()
        try cloud.put(BackendSyncFixtures.remote())
        let local = BackendSyncFixtures.local(hosts: ["new-address.local"])
        #expect(BackendSyncFixtures.publisher(cloud).publish(local) == .published)
        #expect(cloud.items.count == 1)
        #expect(try cloud.object()["hosts"] as? [String] == ["new-address.local", "mac.local", "10.0.0.1"])
    }

    @Test func staleRetryCannotOverwriteNewerEditOrEqualClockRemoval() throws {
        for deleted in [false, true] {
            let cloud = MemorySyncedKeychain()
            try cloud.put(BackendSyncFixtures.remote(clock: deleted ? 1000 : 2000, deleted: deleted))
            let before = cloud.items
            expectSuperseded(BackendSyncFixtures.publisher(cloud).publish(BackendSyncFixtures.local()))
            #expect(cloud.items == before)
            #expect(cloud.writeCount == 0)
        }
    }

    @Test func tombstoneAtAnotherAddressShieldsTheSameFingerprint() throws {
        let cloud = MemorySyncedKeychain()
        var tombstone = BackendSyncFixtures.remote(clock: 2000, deleted: true)
        tombstone["host"] = "old-address.local"
        try cloud.put(tombstone, account: "old-address.local:8843")
        expectSuperseded(BackendSyncFixtures.publisher(cloud).publish(BackendSyncFixtures.local()))
        #expect(cloud.writeCount == 0)
    }

    @Test func deliberateRepairClockBeatsObservedFutureClock() throws {
        let cloud = MemorySyncedKeychain()
        try cloud.put(BackendSyncFixtures.remote(clock: 9000, deleted: true))
        let publisher = BackendSyncFixtures.publisher(cloud, clock: 1000)
        var local = BackendSyncFixtures.local()
        local.pendingSyncUpdatedAt = publisher.pairingClock(for: local)
        #expect(local.pendingSyncUpdatedAt == 9001)
        #expect(publisher.publish(local) == .published)
        #expect(try cloud.object()["deleted"] == nil)
    }

    @Test func newerSchemasAndDifferentCertificatesAreNeverOverwritten() throws {
        let changes: [[String: Any]] = [["v": 2], ["fingerprint": "CC:DD"], ["v": "broken"]]
        for change in changes {
            let cloud = MemorySyncedKeychain()
            var remote = BackendSyncFixtures.remote()
            remote.merge(change) { _, new in new }
            try cloud.put(remote)
            let before = cloud.items
            #expect(BackendSyncFixtures.publisher(cloud).publish(BackendSyncFixtures.local()) == .retry)
            #expect(cloud.items == before)
            #expect(cloud.writeCount == 0)
        }
    }

    @Test func newerSchemaAtAnotherAccountFreezesMatchingFingerprint() throws {
        let cloud = MemorySyncedKeychain()
        var remote = BackendSyncFixtures.remote()
        remote["v"] = 2
        remote["host"] = "old-address.local"
        try cloud.put(remote, account: "old-address.local:8843")
        #expect(BackendSyncFixtures.publisher(cloud).publish(BackendSyncFixtures.local()) == .retry)
        #expect(cloud.writeCount == 0)
    }

    @Test func changeBetweenReadAndWriteDefersTheWrite() throws {
        let cloud = MemorySyncedKeychain()
        try cloud.put(BackendSyncFixtures.remote())
        let newer = try JSONSerialization.data(withJSONObject: BackendSyncFixtures.remote(clock: 2000))
        cloud.beforeList = { count in
            if count == 2 { cloud.items["mac.local:8843"] = newer }
        }
        #expect(BackendSyncFixtures.publisher(cloud).publish(BackendSyncFixtures.local()) == .retry)
        #expect(cloud.writeCount == 0)
        #expect(cloud.items["mac.local:8843"] == newer)
    }

    @Test func duplicateAddDoesNotFallThroughToOverwrite() throws {
        let cloud = MemorySyncedKeychain()
        let newer = try JSONSerialization.data(withJSONObject: BackendSyncFixtures.remote(clock: 2000))
        cloud.beforeWrite = { cloud.items["mac.local:8843"] = newer }
        let publisher = BackendSyncFixtures.publisher(cloud)
        #expect(publisher.publish(BackendSyncFixtures.local()) == .retry)
        #expect(cloud.adds.count == 1)
        #expect(cloud.updates.isEmpty)
        expectSuperseded(publisher.publish(BackendSyncFixtures.local()))
        #expect(cloud.items["mac.local:8843"] == newer)
    }

    @Test func missingGroupLockedReadsAndWriteFailuresStayRetryable() {
        let cloud = MemorySyncedKeychain()
        #expect(SyncedBackendPublisher(keychain: cloud, accessGroup: nil).publish(BackendSyncFixtures.local()) == .retry)
        #expect(cloud.reads == 0)
        cloud.readFailure = errSecInteractionNotAllowed
        #expect(BackendSyncFixtures.publisher(cloud).publish(BackendSyncFixtures.local()) == .retry)
        #expect(cloud.writeCount == 0)
        cloud.readFailure = nil
        cloud.writeFailure = errSecMissingEntitlement
        #expect(BackendSyncFixtures.publisher(cloud).publish(BackendSyncFixtures.local()) == .retry)
    }
}
