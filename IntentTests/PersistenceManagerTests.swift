import Foundation
@testable import Intent
import Security
import Testing

/// Tests for PersistenceManager per-workspace tab persistence.
/// Uses a unique key prefix per test to avoid UserDefaults collisions.
@Suite(.serialized)
struct PersistenceManagerTests {
    // MARK: - MainActor serialization smoke test

    @Test func serializedMainActorSavesMaintainDataIntegrity() async {
        let prefix = "test-ws-concurrent-\(UUID().uuidString)"
        let iterations = 100
        let workspaceIds = (0..<iterations).map { "\(prefix)-\($0)" }

        // Submit many saves as independent tasks; the MainActor contract serializes mutations.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask { @MainActor in
                    let wsId = workspaceIds[i]
                    PersistenceManager.shared.saveWorkspaceTab(workspaceId: wsId, tab: i % 3)
                }
            }
        }

        // Verify all tabs persisted correctly
        for i in 0..<iterations {
            let wsId = workspaceIds[i]
            let tab = PersistenceManager.shared.loadWorkspaceTab(workspaceId: wsId)
            #expect(tab == i % 3, "Workspace \(wsId) tab mismatch (lost update)")
        }
    }
}

/// In-memory `KeychainStorage` so connection-persistence tests are hermetic:
/// SecItem calls fail on headless CI simulators, and real Keychain state would
/// leak between runs.
final class InMemoryKeychainStorage: KeychainStorage, @unchecked Sendable {
    private var items: [String: Data] = [:]
    private var shouldFailSaves = false
    private let lock = NSLock()

    private func key(_ service: String, _ account: String) -> String { "\(service)\u{1F}\(account)" }

    @discardableResult
    func save(data: Data, service: String, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !shouldFailSaves else { return false }
        items[key(service, account)] = data
        return true
    }

    func setSaveFailure(_ shouldFail: Bool) {
        lock.lock()
        shouldFailSaves = shouldFail
        lock.unlock()
    }

    func load(service: String, account: String) -> KeychainReadResult {
        lock.lock()
        defer { lock.unlock() }
        return items[key(service, account)].map(KeychainReadResult.value) ?? .missing
    }

    func delete(service: String, account: String) {
        lock.lock()
        defer { lock.unlock() }
        items.removeValue(forKey: key(service, account))
    }
}

/// Installs the in-memory Keychain backend exactly once per test process.
enum TestKeychainStorage {
    static let installed: Void = {
        PersistenceManager.shared.keychainStorage = InMemoryKeychainStorage()
    }()
}

final class FakeSecItemStore {
    struct Record: Equatable {
        var data: Data
        var accessibility: String
    }

    var items: [String: Record]
    var updateFailure: OSStatus?
    var addFailure: OSStatus?
    var readFailures: [String: OSStatus] = [:]
    var nextReadFailures: [String: OSStatus] = [:]
    var nextUpdateFailure: OSStatus?
    var readOverride: (OSStatus, AnyObject?)?
    private(set) var updateCallCount = 0
    private(set) var addCallCount = 0
    private(set) var deleteCallCount = 0
    /// Raw attribute dictionaries handed to SecItemUpdate / SecItemAdd, so
    /// policy tests can assert exactly what would reach the Security framework.
    private(set) var updateCalls: [(query: [String: Any], attributes: [String: Any])] = []
    private(set) var addQueries: [[String: Any]] = []
    private(set) var readQueries: [[String: Any]] = []

    init(items: [String: Record] = [:]) {
        self.items = items
    }

    func record(service: String, account: String) -> Record? {
        items[key(service: service, account: account)]
    }

    private func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
        readQueries.append(query)
        if let readOverride { return readOverride }
        guard let key = key(from: query), let account = query[kSecAttrAccount as String] as? String else {
            return (errSecParam, nil)
        }
        if let status = nextReadFailures.removeValue(forKey: account) ?? readFailures[account] {
            return (status, nil)
        }
        guard let record = items[key] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, record.data as AnyObject)
    }

    func securityCalls() -> SecItemKeychainStorage.SecurityCalls {
        SecItemKeychainStorage.SecurityCalls(
            copyMatching: { [self] query in copyMatching(query) },
            update: { [self] query, attributes in
                updateCallCount += 1
                updateCalls.append((query: query, attributes: attributes))
                if let failure = nextUpdateFailure {
                    nextUpdateFailure = nil
                    return failure
                }
                if let updateFailure { return updateFailure }
                guard let key = key(from: query), var record = items[key] else {
                    return errSecItemNotFound
                }
                guard let data = attributes[kSecValueData as String] as? Data else {
                    return errSecParam
                }
                record.data = data
                items[key] = record
                return errSecSuccess
            },
            add: { [self] query in
                addCallCount += 1
                addQueries.append(query)
                if let addFailure { return addFailure }
                guard let key = key(from: query), items[key] == nil,
                    let data = query[kSecValueData as String] as? Data,
                    let accessibility = query[kSecAttrAccessible as String] as? String
                else {
                    return errSecParam
                }
                items[key] = Record(data: data, accessibility: accessibility)
                return errSecSuccess
            },
            delete: { [self] query in
                deleteCallCount += 1
                guard let key = key(from: query) else { return errSecParam }
                items.removeValue(forKey: key)
                return errSecSuccess
            }
        )
    }

    private func key(service: String, account: String) -> String {
        "\(service)\u{1F}\(account)"
    }

    private func key(from query: [String: Any]) -> String? {
        guard let service = query[kSecAttrService as String] as? String,
            let account = query[kSecAttrAccount as String] as? String
        else { return nil }
        return key(service: service, account: account)
    }
}

@Suite("SecItem Keychain storage")
struct SecItemKeychainStorageTests {
    private let service = "test.service"
    private let account = "test.account"
    private let original = FakeSecItemStore.Record(
        data: Data("old".utf8),
        accessibility: "existing-accessibility"
    )

    @Test func updateSucceedsWithoutDeleteOrAdd() {
        let fake = FakeSecItemStore(items: ["\(service)\u{1F}\(account)": original])
        let storage = SecItemKeychainStorage(security: fake.securityCalls())
        let replacement = Data("new".utf8)

        #expect(storage.save(data: replacement, service: service, account: account))
        #expect(
            fake.record(service: service, account: account)
                == .init(data: replacement, accessibility: original.accessibility)
        )
        #expect(fake.updateCallCount == 1)
        #expect(fake.addCallCount == 0)
        #expect(fake.deleteCallCount == 0)
    }

    @Test func updateFailurePreservesExistingRecordWithoutFallback() {
        let fake = FakeSecItemStore(items: ["\(service)\u{1F}\(account)": original])
        fake.updateFailure = errSecInteractionNotAllowed
        let storage = SecItemKeychainStorage(security: fake.securityCalls())

        #expect(!storage.save(data: Data("new".utf8), service: service, account: account))
        #expect(fake.record(service: service, account: account) == original)
        #expect(fake.updateCallCount == 1)
        #expect(fake.addCallCount == 0)
        #expect(fake.deleteCallCount == 0)
    }

    @Test func missingItemAddsWithExistingIdentityAndAccessibility() {
        let fake = FakeSecItemStore()
        let storage = SecItemKeychainStorage(security: fake.securityCalls())
        let data = Data("new".utf8)

        #expect(storage.save(data: data, service: service, account: account))
        #expect(
            fake.record(service: service, account: account)
                == .init(
                    data: data,
                    accessibility: kSecAttrAccessibleAfterFirstUnlock as String
                )
        )
        #expect(fake.updateCallCount == 1)
        #expect(fake.addCallCount == 1)
        #expect(fake.deleteCallCount == 0)
    }

    @Test func addFailureLeavesOtherEntriesUntouched() {
        let otherAccount = "other.account"
        let fake = FakeSecItemStore(items: ["\(service)\u{1F}\(otherAccount)": original])
        fake.addFailure = errSecNotAvailable
        let storage = SecItemKeychainStorage(security: fake.securityCalls())

        #expect(!storage.save(data: Data("new".utf8), service: service, account: account))
        #expect(fake.record(service: service, account: account) == nil)
        #expect(fake.record(service: service, account: otherAccount) == original)
        #expect(fake.updateCallCount == 1)
        #expect(fake.addCallCount == 1)
        #expect(fake.deleteCallCount == 0)
    }
}
