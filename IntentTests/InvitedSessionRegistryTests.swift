import Foundation
@testable import Intent
import Security
import Testing

@MainActor struct InvitedSessionRegistryTests {
    @Test func duplicateImmutableRemovalPreservesBytesAndNeverUpdates() throws {
        let cloud = MemorySyncedKeychain()
        let removal = try InvitedSessionFixtures.removal()
        var extended = removal.object
        extended["futureExtension"] = ["keep": true]
        let original = try JSONSerialization.data(withJSONObject: extended, options: [.prettyPrinted])
        cloud.items[removal.account] = original
        let registry = InvitedSessionRegistry(keychain: cloud, accessGroup: BackendSyncFixtures.accessGroup)
        #expect(registry.insertRemoval(removal))
        #expect(cloud.items[removal.account] == original)
        #expect(cloud.updates.isEmpty)
        #expect(cloud.adds.allSatisfy { $0[kSecAttrService as String] as? String == InvitedSessionRegistry.service })
    }

    @Test func partialGroupReadCannotPublishOrAcknowledge() {
        let cloud = MemorySyncedKeychain()
        cloud.beforeList = { [weak cloud] count in
            if count == 2 { cloud?.readFailure = errSecInteractionNotAllowed }
        }
        let registry = InvitedSessionRegistry(keychain: cloud, accessGroup: BackendSyncFixtures.accessGroup)
        #expect(registry.read() == nil)
        #expect(cloud.writeCount == 0)
    }

    @Test func unreadableOrFutureCanonicalAccountFreezesItsBytes() throws {
        let cloud = MemorySyncedKeychain()
        let record = try InvitedSessionFixtures.session()
        let registry = InvitedSessionRegistry(keychain: cloud, accessGroup: BackendSyncFixtures.accessGroup)
        for bytes in [Data("not json".utf8), Data(#"{"v":3}"#.utf8)] {
            cloud.items[record.account] = bytes
            let snapshot = try #require(registry.read())
            #expect(!registry.writeMutable(record, snapshot: snapshot))
            #expect(cloud.items[record.account] == bytes)
        }
        #expect(cloud.writeCount == 0)
    }

    @Test func ownerPublisherCannotPublishInvitedBearerEvenWhenCalledDirectly() throws {
        let cloud = MemorySyncedKeychain()
        var invited = try #require(PersistenceManager.connection(fromInvited: InvitedSessionFixtures.session()))
        invited.principal = InvitedSessionFixtures.principal()
        invited.pendingSyncUpdatedAt = 300
        #expect(BackendSyncFixtures.publisher(cloud).publish(invited) == .retry)
        #expect(cloud.writeCount == 0)
        let owner = BackendSyncFixtures.local()
        #expect(BackendSyncFixtures.publisher(cloud).publish(owner) == .published)
        #expect(cloud.adds.allSatisfy { $0[kSecAttrService as String] as? String == SyncedBackendRegistry.service })
    }

    @Test func freshReadRejectsUnknownPayloadThatArrivedAfterPreparation() throws {
        let cloud = MemorySyncedKeychain()
        let record = try InvitedSessionFixtures.session()
        let registry = InvitedSessionRegistry(keychain: cloud, accessGroup: BackendSyncFixtures.accessGroup)
        let snapshot = try #require(registry.read())
        cloud.items[record.account] = Data(#"{"v":99}"#.utf8)
        #expect(!registry.writeMutable(record, snapshot: snapshot))
        #expect(cloud.writeCount == 0)
    }
}
