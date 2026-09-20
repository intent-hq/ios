import Foundation
@testable import Intent
import Security
import Testing

/// Pins the credential backup / accessibility policy documented on
/// `SecItemKeychainStorage` (ios#263): every LOCAL credential class is
/// `AfterFirstUnlock`, non-synchronizable and app-private; SYNCED backend
/// records are read as synchronizable shared-group items with no
/// accessibility constraint of their own. Any drift in these attributes —
/// including a move to a `ThisDeviceOnly` class — must fail here and come
/// with an explicit policy decision plus a migration.
@Suite("Keychain credential backup policy")
struct KeychainAccessibilityPolicyTests {
    private func makePersistence(
        fake: FakeSecItemStore
    ) throws -> (manager: PersistenceManager, suiteName: String) {
        let suiteName = "KeychainAccessibilityPolicyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let storage = SecItemKeychainStorage(security: fake.securityCalls())
        return (PersistenceManager(defaults: defaults, keychainStorage: storage), suiteName)
    }

    @Test func everyLocalCredentialClassIsAfterFirstUnlockAndNeverSynchronizable() throws {
        let fake = FakeSecItemStore()
        let setup = try makePersistence(fake: fake)
        defer { UserDefaults(suiteName: setup.suiteName)?.removePersistentDomain(forName: setup.suiteName) }
        let manager = setup.manager
        let localAccounts = [
            manager.keychainAccountConnections,
            manager.keychainAccountToken,
            manager.keychainAccountServer
        ]

        for account in localAccounts {
            #expect(manager.saveDataToKeychain(data: Data(account.utf8), account: account))
        }

        #expect(fake.addQueries.count == localAccounts.count)
        #expect(
            fake.addQueries.compactMap { $0[kSecAttrAccount as String] as? String }
                == localAccounts
        )
        for query in fake.addQueries {
            #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
            #expect(query[kSecAttrService as String] as? String == "com.intent.companion")
            #expect(
                query[kSecAttrAccessible as String] as? String
                    == kSecAttrAccessibleAfterFirstUnlock as String
            )
            #expect(query[kSecAttrSynchronizable as String] == nil)
            #expect(query[kSecAttrAccessGroup as String] == nil)
        }
    }

    @Test func rewritingALocalCredentialNeverTouchesItsAccessibilityOrSyncScope() throws {
        let fake = FakeSecItemStore()
        let setup = try makePersistence(fake: fake)
        defer { UserDefaults(suiteName: setup.suiteName)?.removePersistentDomain(forName: setup.suiteName) }
        let manager = setup.manager

        #expect(
            manager.saveDataToKeychain(
                data: Data("first".utf8),
                account: manager.keychainAccountConnections
            )
        )
        #expect(
            manager.saveDataToKeychain(
                data: Data("second".utf8),
                account: manager.keychainAccountConnections
            )
        )

        #expect(fake.addCallCount == 1)
        #expect(fake.updateCalls.count == 2)
        for call in fake.updateCalls {
            #expect(call.query[kSecAttrSynchronizable as String] == nil)
            #expect(call.query[kSecAttrAccessGroup as String] == nil)
            #expect(Array(call.attributes.keys) == [kSecValueData as String])
        }
        #expect(
            fake.record(service: "com.intent.companion", account: manager.keychainAccountConnections)?
                .accessibility == kSecAttrAccessibleAfterFirstUnlock as String
        )
    }

    @Test func syncedBackendRecordsAreReadAsSynchronizableSharedGroupItemsOnly() {
        let group = "T.dev.intentapp.backends"
        let query = SyncedBackendRegistry.listQuery(accessGroup: group)

        #expect(query[kSecAttrService as String] as? String == "com.cloudlands.intent.backends")
        #expect(query[kSecAttrAccessGroup as String] as? String == group)
        #expect(
            query[kSecAttrSynchronizable as String] as? String
                == kSecAttrSynchronizableAny as String
        )
        #expect(query[kSecAttrAccessible as String] == nil)
        #expect(query[kSecValueData as String] == nil)
    }
}
