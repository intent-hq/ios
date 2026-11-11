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

@MainActor
struct DraftPersistenceTests {
    private func withStore(_ body: (PersistenceManager, UserDefaults, BackendID, BackendID) throws -> Void) throws {
        let suite = "DraftPersistenceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = PersistenceManager(defaults: defaults, keychainStorage: InMemoryKeychainStorage())
        let first = persistence.upsertConnection(StoredConnection(
            server: PairedServer(hosts: ["first.local"], port: 4242, name: "First", pairedAt: Date()), token: "first"
        ))
        let second = persistence.upsertConnection(StoredConnection(
            server: PairedServer(hosts: ["second.local"], port: 4242, name: "Second", pairedAt: Date()), token: "second"
        ))
        persistence.setActiveConnection(id: first.id)
        try body(persistence, defaults, BackendID(first.id), BackendID(second.id))
    }

    @Test func legacyDraftMigratesOnlyToActiveBackendAndSurvivesRestart() throws {
        try withStore { persistence, defaults, first, second in
            // Seed the exact key written by the previous app version.
            defaults.set("Saved before upgrade", forKey: "draft_workspace_agent")
            #expect(persistence.loadDraft(workspaceId: "workspace", agentId: "agent", backendID: second).isEmpty)
            #expect(defaults.string(forKey: "draft_workspace_agent") == "Saved before upgrade")
            #expect(persistence.loadDraft(workspaceId: "workspace", agentId: "agent", backendID: first) == "Saved before upgrade")
            #expect(defaults.object(forKey: "draft_workspace_agent") == nil)
            persistence.setActiveConnection(id: second.connectionID)
            let restarted = PersistenceManager(defaults: defaults, keychainStorage: persistence.keychainStorage)
            #expect(restarted.loadDraft(workspaceId: "workspace", agentId: "agent", backendID: second).isEmpty)
            #expect(restarted.loadDraft(workspaceId: "workspace", agentId: "agent", backendID: first) == "Saved before upgrade")
        }
    }

    @Test func switchingBeforeFirstReadPreservesAllLegacyDraftOwnership() throws {
        try withStore { persistence, defaults, first, second in
            defaults.set("First conversation", forKey: "draft_workspace_agent")
            defaults.set("Another conversation", forKey: "draft_other_agent")
            persistence.setActiveConnection(id: second.connectionID)
            let restarted = PersistenceManager(defaults: defaults, keychainStorage: persistence.keychainStorage)
            for workspace in ["workspace", "other"] {
                #expect(restarted.loadDraft(workspaceId: workspace, agentId: "agent", backendID: second).isEmpty)
            }
            #expect(restarted.loadDraft(workspaceId: "workspace", agentId: "agent", backendID: first) == "First conversation")
            #expect(restarted.loadDraft(workspaceId: "other", agentId: "agent", backendID: first) == "Another conversation")
        }
    }

    @Test func removingLegacyOwnerDoesNotGiveDraftToAnotherBackend() throws {
        try withStore { persistence, defaults, first, second in
            defaults.set("Removed backend's draft", forKey: "draft_workspace_agent")
            #expect(persistence.deleteConnection(id: first.connectionID))
            persistence.setActiveConnection(id: second.connectionID)
            #expect(persistence.loadDraft(workspaceId: "workspace", agentId: "agent", backendID: second).isEmpty)
            #expect(defaults.string(forKey: "draft_workspace_agent") == "Removed backend's draft")
        }
    }

    @Test func newerScopedDraftWinsAndConsumesLegacyValue() throws {
        try withStore { persistence, defaults, first, _ in
            defaults.set("Old draft", forKey: "draft_workspace_agent")
            defaults.set("New draft", forKey: "draft_\(first.connectionID.uuidString)_workspace_agent")
            #expect(persistence.loadDraft(workspaceId: "workspace", agentId: "agent", backendID: first) == "New draft")
            #expect(defaults.object(forKey: "draft_workspace_agent") == nil)
            persistence.clearDraft(workspaceId: "workspace", agentId: "agent", backendID: first)
            #expect(persistence.loadDraft(workspaceId: "workspace", agentId: "agent", backendID: first).isEmpty)
        }
    }

    @Test(arguments: ["clear", "empty", "replace"])
    func scopedWritesConsumeLegacyDraftBeforeFirstRead(operation: String) throws {
        try withStore { persistence, defaults, first, _ in
            defaults.set("Old draft", forKey: "draft_workspace_agent")
            if operation == "clear" {
                persistence.clearDraft(workspaceId: "workspace", agentId: "agent", backendID: first)
            } else {
                persistence.saveDraft(operation == "empty" ? "" : "Replacement", workspaceId: "workspace", agentId: "agent", backendID: first)
            }
            #expect(defaults.object(forKey: "draft_workspace_agent") == nil)
            #expect(persistence.loadDraft(workspaceId: "workspace", agentId: "agent", backendID: first) == (operation == "replace" ? "Replacement" : ""))
        }
    }

    @Test func otherBackendWritesLeaveLegacyDraftForOwner() throws {
        try withStore { persistence, defaults, first, second in
            defaults.set("Owner's draft", forKey: "draft_workspace_agent")
            persistence.clearDraft(workspaceId: "workspace", agentId: "agent", backendID: second)
            persistence.saveDraft("Other draft", workspaceId: "workspace", agentId: "agent", backendID: second)
            #expect(persistence.loadDraft(workspaceId: "workspace", agentId: "agent", backendID: first) == "Owner's draft")
            #expect(persistence.loadDraft(workspaceId: "workspace", agentId: "agent", backendID: second) == "Other draft")
        }
    }

    @Test func malformedRegistryDoesNotClaimOrDiscardLegacyDraft() throws {
        try withStore { persistence, defaults, first, _ in
            persistence.saveDataToKeychain(data: Data("invalid registry".utf8), account: persistence.keychainAccountConnections)
            defaults.set("Recoverable draft", forKey: "draft_workspace_agent")
            #expect(persistence.loadDraft(workspaceId: "workspace", agentId: "agent", backendID: first).isEmpty)
            #expect(defaults.string(forKey: "draft_workspace_agent") == "Recoverable draft")
            #expect(defaults.object(forKey: "legacyDraftOwner") == nil)
        }
    }

    @Test func unresolvedOwnerLeavesLegacyDraftUntouchedUntilActiveConnectionResolves() throws {
        try withStore { persistence, defaults, first, _ in
            defaults.removeObject(forKey: persistence.activeConnectionIdKey)
            defaults.set("Waiting for owner", forKey: "draft_workspace_agent")
            #expect(persistence.loadDraft(workspaceId: "workspace", agentId: "agent", backendID: first).isEmpty)
            #expect(defaults.string(forKey: "draft_workspace_agent") == "Waiting for owner")
            persistence.setActiveConnection(id: first.connectionID)
            #expect(persistence.loadDraft(workspaceId: "workspace", agentId: "agent", backendID: first) == "Waiting for owner")
        }
    }
}
