import Foundation
import Security
import Testing

@testable import Intent

/// Shared fake for the writer and a second client's ordinary registry reader.
/// Stores exactly the JSON bytes handed to Security, never real credentials.
nonisolated final class MemorySyncedKeychain: SyncedKeychainWriting {
    var items: [String: Data] = [:]
    var readFailure: OSStatus?
    var writeFailure: OSStatus?
    var beforeWrite: (() -> Void)?
    var beforeList: ((Int) -> Void)?
    private(set) var reads = 0
    private(set) var adds: [[String: Any]] = []
    private(set) var updates: [(query: [String: Any], attributes: [String: Any])] = []
    var writeCount: Int { adds.count + updates.count }

    func list(matching _: [String: Any]) -> SyncedKeychainListOutcome {
        reads += 1
        beforeList?(reads)
        if let readFailure { return .failure(readFailure) }
        return .rows(items.map { [kSecAttrAccount as String: $0.key, kSecValueData as String: $0.value] })
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        adds.append(attributes)
        beforeWrite?()
        if let writeFailure { return writeFailure }
        guard let account = attributes[kSecAttrAccount as String] as? String,
              let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
        guard items[account] == nil else { return errSecDuplicateItem }
        items[account] = data
        return errSecSuccess
    }

    func update(matching query: [String: Any], attributes: [String: Any]) -> OSStatus {
        updates.append((query, attributes))
        beforeWrite?()
        if let writeFailure { return writeFailure }
        guard let account = query[kSecAttrAccount as String] as? String,
              let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
        guard items[account] != nil else { return errSecItemNotFound }
        items[account] = data
        return errSecSuccess
    }

    func put(_ object: [String: Any], account: String = "mac.local:8843") throws {
        items[account] = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func object(account: String = "mac.local:8843") throws -> [String: Any] {
        let data = try #require(items[account])
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

enum BackendSyncFixtures {
    static let accessGroup = "TESTTEAM.dev.intentapp.backends"
    static let route = "tcMiXeD_Case-Address"
    private static let millisecondsPerSecond: Double = 1000
    private static let port = 8843
    private static let futureValues = [1, 2]

    static func local(clock: Double = 1000, hosts: [String] = ["Mac.Local"], token: String = "local-token") -> StoredConnection {
        var connection = StoredConnection(
            server: PairedServer(
                hosts: hosts,
                port: port,
                name: "Mac",
                pairedAt: Date(timeIntervalSince1970: clock / millisecondsPerSecond),
                certFingerprint: "aa:bb",
                tcAddress: route
            ),
            token: token,
            displayName: "My Mac"
        )
        connection.principal = .demoOwner
        connection.pendingSyncUpdatedAt = clock
        return connection
    }

    static func remote(clock: Double = 100, deleted: Bool = false) -> [String: Any] {
        [
            "v": 1, "host": "mac.local", "hosts": ["mac.local", "10.0.0.1"], "port": port,
            "fingerprint": "AA:BB", "token": deleted ? "" : "remote-token", "label": "Desktop name",
            "updatedAt": clock, "deleted": deleted, "deletedAt": clock,
            "tcAddress": "tcDesktop", "detectHosts": false, "hostname": "real-hostname",
            "accent": "blue", "deviceIcon": "auto", "detectedDeviceKind": "mac",
            "futureMetadata": ["enabled": true, "values": futureValues]
        ]
    }

    static func publisher(_ cloud: MemorySyncedKeychain, clock: Double = 1000) -> SyncedBackendPublisher {
        SyncedBackendPublisher(keychain: cloud, accessGroup: accessGroup) {
            Date(timeIntervalSince1970: clock / millisecondsPerSecond)
        }
    }
}

struct BackendSyncTestStore {
    let suiteName: String
    let defaults: UserDefaults
    let local: InMemoryKeychainStorage
    let cloud: MemorySyncedKeychain
    let manager: PersistenceManager

    init(clock: Double = 1000) throws {
        let suiteName = "BackendSyncTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let local = InMemoryKeychainStorage()
        let cloud = MemorySyncedKeychain()
        self.suiteName = suiteName
        self.defaults = defaults
        self.local = local
        self.cloud = cloud
        manager = PersistenceManager(
            defaults: defaults,
            keychainStorage: local,
            backendPublisher: BackendSyncFixtures.publisher(cloud, clock: clock)
        )
    }

    func cleanUp() { defaults.removePersistentDomain(forName: suiteName) }

    func seed(_ connections: [StoredConnection]) throws {
        #expect(manager.saveDataToKeychain(data: try JSONEncoder().encode(connections), account: manager.keychainAccountConnections))
    }
}

extension PersistenceManager {
    /// These publication fixtures model an owner already confirmed by the
    /// connection. The legacy savePairing shim intentionally has no authority.
    func saveVerifiedOwnerForTesting(server: PairedServer, token: String) -> Bool {
        var connection = StoredConnection(server: server, token: token)
        connection.principal = .demoOwner
        let outcome = upsertConnectionWithOutcome(connection)
        guard outcome.persisted, setActiveConnection(id: outcome.connection.id) else { return false }
        publishPendingBackends()
        return true
    }
}
