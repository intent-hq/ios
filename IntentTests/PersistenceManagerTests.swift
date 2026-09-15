import Foundation
@testable import Intent
import Security
import Testing

/// Tests for PersistenceManager per-workspace screen persistence.
/// Uses a unique key prefix per test to avoid UserDefaults collisions.
@Suite(.serialized)
struct PersistenceManagerTests {
    // MARK: - Setup / Teardown helper

    /// Clean up UserDefaults keys used by PersistenceManager for workspace screens.
    private func cleanup(workspaceIds: [String]) {
        for id in workspaceIds {
            PersistenceManager.shared.clearWorkspaceScreen(workspaceId: id)
        }
    }

    // MARK: - saveWorkspaceScreen / loadWorkspaceScreen round-trip

    @Test func roundTripConversationScreen() {
        let wsId = "test-ws-roundtrip-conv-\(UUID().uuidString)"
        defer { cleanup(workspaceIds: [wsId]) }

        let screen = PersistenceManager.SavedScreen(
            screen: "conversation",
            workspaceId: wsId,
            agentId: "agent-42",
            agentName: "Builder",
            noteId: nil,
            noteTitle: nil
        )
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: wsId, screen: screen)
        let loaded = PersistenceManager.shared.loadWorkspaceScreen(workspaceId: wsId)
        #expect(loaded != nil)
        #expect(loaded?.screen == "conversation")
        #expect(loaded?.agentId == "agent-42")
        #expect(loaded?.agentName == "Builder")
        #expect(loaded?.workspaceId == wsId)
    }

    @Test func roundTripNoteScreen() {
        let wsId = "test-ws-roundtrip-note-\(UUID().uuidString)"
        defer { cleanup(workspaceIds: [wsId]) }

        let screen = PersistenceManager.SavedScreen(
            screen: "note",
            workspaceId: wsId,
            agentId: nil,
            agentName: nil,
            noteId: "note-123",
            noteTitle: "My Note"
        )
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: wsId, screen: screen)
        let loaded = PersistenceManager.shared.loadWorkspaceScreen(workspaceId: wsId)
        #expect(loaded != nil)
        #expect(loaded?.screen == "note")
        #expect(loaded?.noteId == "note-123")
        #expect(loaded?.noteTitle == "My Note")
    }

    // MARK: - Load returns nil for unknown workspace

    @Test func loadReturnsNilForUnknownWorkspace() {
        let loaded = PersistenceManager.shared.loadWorkspaceScreen(
            workspaceId: "nonexistent-ws-\(UUID().uuidString)"
        )
        #expect(loaded == nil)
    }

    // MARK: - clearWorkspaceScreen

    @Test func clearRemovesSavedScreen() {
        let wsId = "test-ws-clear-\(UUID().uuidString)"
        defer { cleanup(workspaceIds: [wsId]) }

        let screen = PersistenceManager.SavedScreen(
            screen: "conversation",
            workspaceId: wsId,
            agentId: "a",
            agentName: "A",
            noteId: nil,
            noteTitle: nil
        )
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: wsId, screen: screen)
        #expect(PersistenceManager.shared.loadWorkspaceScreen(workspaceId: wsId) != nil)

        PersistenceManager.shared.clearWorkspaceScreen(workspaceId: wsId)
        #expect(PersistenceManager.shared.loadWorkspaceScreen(workspaceId: wsId) == nil)
    }

    // MARK: - Independent workspaces

    @Test func differentWorkspacesMaintainIndependentScreens() {
        let ws1 = "test-ws-indep-1-\(UUID().uuidString)"
        let ws2 = "test-ws-indep-2-\(UUID().uuidString)"
        defer { cleanup(workspaceIds: [ws1, ws2]) }

        let screen1 = PersistenceManager.SavedScreen(
            screen: "conversation",
            workspaceId: ws1,
            agentId: "agent-A",
            agentName: "A",
            noteId: nil,
            noteTitle: nil
        )
        let screen2 = PersistenceManager.SavedScreen(
            screen: "note",
            workspaceId: ws2,
            agentId: nil,
            agentName: nil,
            noteId: "note-B",
            noteTitle: "B"
        )
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: ws1, screen: screen1)
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: ws2, screen: screen2)

        let loaded1 = PersistenceManager.shared.loadWorkspaceScreen(workspaceId: ws1)
        let loaded2 = PersistenceManager.shared.loadWorkspaceScreen(workspaceId: ws2)
        #expect(loaded1?.screen == "conversation")
        #expect(loaded1?.agentId == "agent-A")
        #expect(loaded2?.screen == "note")
        #expect(loaded2?.noteId == "note-B")
    }

    @Test func clearOneWorkspaceDoesNotAffectOther() {
        let ws1 = "test-ws-clear-one-\(UUID().uuidString)"
        let ws2 = "test-ws-clear-other-\(UUID().uuidString)"
        defer { cleanup(workspaceIds: [ws1, ws2]) }

        let screen = PersistenceManager.SavedScreen(
            screen: "conversation",
            workspaceId: ws1,
            agentId: "a",
            agentName: "A",
            noteId: nil,
            noteTitle: nil
        )
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: ws1, screen: screen)
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: ws2, screen: screen)

        PersistenceManager.shared.clearWorkspaceScreen(workspaceId: ws1)
        #expect(PersistenceManager.shared.loadWorkspaceScreen(workspaceId: ws1) == nil)
        #expect(PersistenceManager.shared.loadWorkspaceScreen(workspaceId: ws2) != nil)
    }

    // MARK: - Overwrite

    @Test func savingOverwritesPreviousScreen() {
        let wsId = "test-ws-overwrite-\(UUID().uuidString)"
        defer { cleanup(workspaceIds: [wsId]) }

        let first = PersistenceManager.SavedScreen(
            screen: "conversation",
            workspaceId: wsId,
            agentId: "a1",
            agentName: "First",
            noteId: nil,
            noteTitle: nil
        )
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: wsId, screen: first)

        let second = PersistenceManager.SavedScreen(
            screen: "note",
            workspaceId: wsId,
            agentId: nil,
            agentName: nil,
            noteId: "n2",
            noteTitle: "Second"
        )
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: wsId, screen: second)

        let loaded = PersistenceManager.shared.loadWorkspaceScreen(workspaceId: wsId)
        #expect(loaded?.screen == "note")
        #expect(loaded?.noteId == "n2")
    }

    // MARK: - MainActor serialization smoke test

    @Test func serializedMainActorSavesMaintainDataIntegrity() async {
        let prefix = "test-ws-concurrent-\(UUID().uuidString)"
        let iterations = 100
        let workspaceIds = (0..<iterations).map { "\(prefix)-\($0)" }
        defer { cleanup(workspaceIds: workspaceIds) }

        // Submit many saves as independent tasks; the MainActor contract serializes mutations.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask { @MainActor in
                    let wsId = workspaceIds[i]
                    let screen = PersistenceManager.SavedScreen(
                        screen: "conversation",
                        workspaceId: wsId,
                        agentId: "agent-\(i)",
                        agentName: "Agent\(i)",
                        noteId: nil,
                        noteTitle: nil
                    )
                    PersistenceManager.shared.saveWorkspaceScreen(workspaceId: wsId, screen: screen)
                }
            }
        }

        // Assert ALL entries are present and decodable (no lost updates)
        for i in 0..<iterations {
            let wsId = workspaceIds[i]
            let loaded = PersistenceManager.shared.loadWorkspaceScreen(workspaceId: wsId)
            #expect(loaded != nil, "Workspace \(wsId) missing (lost update)")
            #expect(loaded?.screen == "conversation")
            #expect(loaded?.agentId == "agent-\(i)")
            #expect(loaded?.agentName == "Agent\(i)")
        }

        // Also exercise workspaceTabs with the same multi-task scheduling.
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

    func load(service: String, account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items[key(service, account)]
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

private final class FakeSecItemStore {
    struct Record: Equatable {
        var data: Data
        var accessibility: String
    }

    var items: [String: Record]
    var updateFailure: OSStatus?
    var addFailure: OSStatus?
    private(set) var updateCallCount = 0
    private(set) var addCallCount = 0
    private(set) var deleteCallCount = 0

    init(items: [String: Record] = [:]) {
        self.items = items
    }

    func record(service: String, account: String) -> Record? {
        items[key(service: service, account: account)]
    }

    func securityCalls() -> SecItemKeychainStorage.SecurityCalls {
        SecItemKeychainStorage.SecurityCalls(
            update: { [self] query, attributes in
                updateCallCount += 1
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
                if let addFailure { return addFailure }
                guard let key = key(from: query), items[key] == nil,
                      let data = query[kSecValueData as String] as? Data,
                      let accessibility = query[kSecAttrAccessible as String] as? String else {
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
              let account = query[kSecAttrAccount as String] as? String else { return nil }
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
