import Foundation
import Security
import Testing

@testable import Intent

/// In-memory `SyncedKeychainListing` capturing queries and returning a
/// canned outcome (SecItem calls fail in headless CI simulators).
final class FakeSyncedKeychain: SyncedKeychainListing, @unchecked Sendable {
    var outcome: SyncedKeychainListOutcome
    private(set) var capturedQueries: [[String: Any]] = []

    init(outcome: SyncedKeychainListOutcome = .notFound) {
        self.outcome = outcome
    }

    func list(matching query: [String: Any]) -> SyncedKeychainListOutcome {
        capturedQueries.append(query)
        return outcome
    }
}

/// A keychain list row as SecItemCopyMatching would return it.
private func row(account: String, payload: String) -> [String: Any] {
    [
        kSecAttrAccount as String: account,
        kSecValueData as String: Data(payload.utf8),
    ]
}

/// A valid v1 live payload with every field populated plus an unknown field.
private let livePayload = """
    {"v": 1, "label": "Mac Studio", "host": "192.168.1.20", \
    "hosts": ["192.168.1.20", "10.0.0.5"], "port": 8843, \
    "fingerprint": "ab:cd:ef", "hostname": "mac-studio.local", \
    "detectHosts": false, "token": "secret-token", "updatedAt": 1700000000000, \
    "someFutureField": {"nested": true}}
    """

// MARK: - Payload parsing

struct SyncedBackendPayloadTests {

    @Test func parsesLivePayloadAndToleratesUnknownFields() throws {
        let parsed = SyncedBackendPayload.parse(livePayload)
        guard case .record(let record) = parsed else {
            Issue.record("expected .record, got \(parsed)")
            return
        }
        #expect(record.label == "Mac Studio")
        #expect(record.host == "192.168.1.20")
        #expect(record.hosts == ["192.168.1.20", "10.0.0.5"])
        #expect(record.port == 8843)
        #expect(record.fingerprint == "ab:cd:ef")
        #expect(record.hostname == "mac-studio.local")
        #expect(record.detectHosts == false)
        #expect(record.token == "secret-token")
        #expect(record.updatedAt == 1_700_000_000_000)
        #expect(record.deleted == false)
        #expect(record.deletedAt == nil)
    }

    @Test func appliesOptionalFieldDefaults() throws {
        let payload = """
            {"v": 1, "label": "L", "host": "Host.Local", "port": 1, \
            "fingerprint": "", "updatedAt": 5, "hostname": null}
            """
        guard case .record(let record) = SyncedBackendPayload.parse(payload) else {
            Issue.record("expected .record")
            return
        }
        #expect(record.hosts == ["Host.Local"])
        #expect(record.hostname == nil)
        #expect(record.detectHosts == true)
        #expect(record.token == "")
    }

    @Test func nonStringHostsEntryFallsBackToHost() throws {
        let payload = """
            {"v": 1, "label": "L", "host": "h", "hosts": ["h", 42], "port": 1, \
            "fingerprint": "f", "updatedAt": 5}
            """
        guard case .record(let record) = SyncedBackendPayload.parse(payload) else {
            Issue.record("expected .record")
            return
        }
        #expect(record.hosts == ["h"])
    }

    @Test func tombstoneScrubsTokenAndDefaultsDeletedAt() throws {
        let payload = """
            {"v": 1, "label": "L", "host": "h", "port": 1, "fingerprint": "f", \
            "token": "leaked", "updatedAt": 77, "deleted": true}
            """
        guard case .record(let record) = SyncedBackendPayload.parse(payload) else {
            Issue.record("expected .record")
            return
        }
        #expect(record.deleted == true)
        #expect(record.token == "")
        #expect(record.deletedAt == 77)
    }

    @Test func tombstoneKeepsExplicitDeletedAt() throws {
        let payload = """
            {"v": 1, "label": "L", "host": "h", "port": 1, "fingerprint": "f", \
            "updatedAt": 77, "deleted": true, "deletedAt": 99}
            """
        guard case .record(let record) = SyncedBackendPayload.parse(payload) else {
            Issue.record("expected .record")
            return
        }
        #expect(record.deletedAt == 99)
    }

    @Test func nonBooleanDeletedIsNotATombstone() throws {
        let payload = """
            {"v": 1, "label": "L", "host": "h", "port": 1, "fingerprint": "f", \
            "token": "t", "updatedAt": 77, "deleted": 1}
            """
        guard case .record(let record) = SyncedBackendPayload.parse(payload) else {
            Issue.record("expected .record")
            return
        }
        #expect(record.deleted == false)
        #expect(record.token == "t")
    }

    @Test func newerVersionIsFrozenNotMisparsed() {
        let payload = """
            {"v": 2, "label": "L", "host": "h", "port": 1, "fingerprint": "f", \
            "updatedAt": 5}
            """
        #expect(SyncedBackendPayload.parse(payload) == .newerVersion)
    }

    @Test func fractionalVersionAboveCurrentIsNewerNotTruncated() {
        let payload = """
            {"v": 1.5, "label": "L", "host": "h", "port": 1, "fingerprint": "f", \
            "updatedAt": 5}
            """
        #expect(SyncedBackendPayload.parse(payload) == .newerVersion)
    }

    @Test func fractionalPortIsInvalidNotTruncated() {
        let payload = """
            {"v": 1, "label": "L", "host": "h", "port": 8843.5, "fingerprint": "f", \
            "updatedAt": 5}
            """
        #expect(SyncedBackendPayload.parse(payload) == .invalid)
    }

    @Test(arguments: [
        "not json at all",
        "[1, 2, 3]",
        "null",
        #"{"label": "no version", "host": "h", "port": 1, "fingerprint": "f", "updatedAt": 5}"#,
        #"{"v": "1", "label": "L", "host": "h", "port": 1, "fingerprint": "f", "updatedAt": 5}"#,
        #"{"v": true, "label": "L", "host": "h", "port": 1, "fingerprint": "f", "updatedAt": 5}"#,
        #"{"v": 1, "host": "h", "port": 1, "fingerprint": "f", "updatedAt": 5}"#,
        #"{"v": 1, "label": "L", "host": "", "port": 1, "fingerprint": "f", "updatedAt": 5}"#,
        #"{"v": 1, "label": "L", "host": "   ", "port": 1, "fingerprint": "f", "updatedAt": 5}"#,
        #"{"v": 1, "label": "L", "host": "h", "port": "1", "fingerprint": "f", "updatedAt": 5}"#,
        #"{"v": 1, "label": "L", "host": "h", "port": true, "fingerprint": "f", "updatedAt": 5}"#,
        #"{"v": 1, "label": "L", "host": "h", "port": 1, "updatedAt": 5}"#,
        #"{"v": 1, "label": "L", "host": "h", "port": 1, "fingerprint": "f"}"#,
        #"{"v": 1, "label": "L", "host": "h", "port": 1, "fingerprint": "f", "updatedAt": "5"}"#,
    ])
    func malformedPayloadIsInvalid(payload: String) {
        #expect(SyncedBackendPayload.parse(payload) == .invalid)
    }
}

// MARK: - Identity keys + access group

struct SyncedBackendIdentityTests {

    private func record(fingerprint: String, host: String = "H", port: Int = 1)
        -> SyncedBackendRecord
    {
        SyncedBackendRecord(
            label: "L", host: host, hosts: [host], port: port, fingerprint: fingerprint,
            hostname: nil, detectHosts: true, token: "", updatedAt: 0,
            deleted: false, deletedAt: nil)
    }

    @Test func registryKeyNormalizesFingerprint() {
        #expect(record(fingerprint: "  ab:cd ").registryKey == "fp:AB:CD")
    }

    @Test func registryKeyFallsBackToNormalizedHostPort() {
        #expect(
            record(fingerprint: "   ", host: " Mac.Local ", port: 88).registryKey
                == "addr:mac.local:88")
    }

    @Test func sharedAccessGroupRequiresPrefix() {
        #expect(SyncedBackendRegistry.sharedAccessGroup(appIdentifierPrefix: nil) == nil)
        #expect(SyncedBackendRegistry.sharedAccessGroup(appIdentifierPrefix: "") == nil)
        #expect(SyncedBackendRegistry.sharedAccessGroup(appIdentifierPrefix: "  ") == nil)
    }

    @Test func sharedAccessGroupJoinsPrefixAndSuffix() {
        #expect(
            SyncedBackendRegistry.sharedAccessGroup(appIdentifierPrefix: "TEAM123.")
                == "TEAM123.dev.intentapp.backends")
        #expect(
            SyncedBackendRegistry.sharedAccessGroup(appIdentifierPrefix: "TEAM123")
                == "TEAM123.dev.intentapp.backends")
    }
}

// MARK: - Registry list

struct SyncedBackendRegistryTests {

    private func registry(_ keychain: FakeSyncedKeychain, group: String? = "T.dev.intentapp.backends")
        -> SyncedBackendRegistry
    {
        SyncedBackendRegistry(keychain: keychain, accessGroup: group)
    }

    @Test func listQueryIsGroupScopedAndSynchronizableAny() {
        let query = SyncedBackendRegistry.listQuery(accessGroup: "T.dev.intentapp.backends")
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "com.cloudlands.intent.backends")
        #expect(query[kSecAttrAccessGroup as String] as? String == "T.dev.intentapp.backends")
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(
            query[kSecAttrSynchronizable as String] as? String
                == kSecAttrSynchronizableAny as String)
        #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String)
        #expect(query[kSecReturnAttributes as String] as? Bool == true)
        #expect(query[kSecReturnData as String] as? Bool == true)
    }

    @Test func listSendsTheGroupScopedQuery() {
        let keychain = FakeSyncedKeychain()
        _ = registry(keychain).listLiveBackends()
        #expect(keychain.capturedQueries.count == 1)
        let query = keychain.capturedQueries.first ?? [:]
        #expect(query[kSecAttrAccessGroup as String] as? String == "T.dev.intentapp.backends")
        #expect(query[kSecAttrService as String] as? String == "com.cloudlands.intent.backends")
    }

    @Test func unresolvedAccessGroupIsUnavailableWithoutQuerying() {
        let keychain = FakeSyncedKeychain()
        let result = registry(keychain, group: nil).listLiveBackends()
        #expect(result == .unavailable(.accessGroupUnresolved))
        #expect(keychain.capturedQueries.isEmpty)
    }

    @Test(arguments: [errSecMissingEntitlement, errSecNotAvailable, errSecInteractionNotAllowed])
    func secItemFailureIsUnavailableNotEmpty(status: OSStatus) {
        let keychain = FakeSyncedKeychain(outcome: .failure(status))
        #expect(registry(keychain).listLiveBackends() == .unavailable(.keychainError(status)))
    }

    @Test func notFoundAndZeroRowsAreEmptyNotUnavailable() {
        #expect(
            registry(FakeSyncedKeychain(outcome: .notFound)).listLiveBackends()
                == .available([]))
        #expect(
            registry(FakeSyncedKeychain(outcome: .rows([]))).listLiveBackends()
                == .available([]))
    }

    @Test func filtersTombstonesNewerVersionAndMalformedRows() {
        let keychain = FakeSyncedKeychain(outcome: .rows([
            row(account: "192.168.1.20:8843", payload: livePayload),
            row(
                account: "10.0.0.9:9000",
                payload: #"{"v": 1, "label": "Gone", "host": "10.0.0.9", "port": 9000, "#
                    + #""fingerprint": "dd", "updatedAt": 2, "deleted": true}"#),
            row(account: "10.0.0.8:9000", payload: #"{"v": 9, "future": true}"#),
            row(account: "10.0.0.7:9000", payload: "not json"),
            [kSecAttrAccount as String: "row-without-data"],
        ]))
        guard case .available(let records) = registry(keychain).listLiveBackends() else {
            Issue.record("expected .available")
            return
        }
        #expect(records.count == 1)
        #expect(records.first?.label == "Mac Studio")
    }

    @Test func collapsesSameFingerprintToNewestRecord() {
        let old = #"{"v": 1, "label": "Old Addr", "host": "10.0.0.1", "port": 1, "#
            + #""fingerprint": "aa:bb", "updatedAt": 100}"#
        let new = #"{"v": 1, "label": "New Addr", "host": "10.0.0.2", "port": 2, "#
            + #""fingerprint": " aa:bb ", "updatedAt": 200}"#
        let keychain = FakeSyncedKeychain(outcome: .rows([
            row(account: "10.0.0.1:1", payload: old),
            row(account: "10.0.0.2:2", payload: new),
        ]))
        guard case .available(let records) = registry(keychain).listLiveBackends() else {
            Issue.record("expected .available")
            return
        }
        #expect(records.count == 1)
        #expect(records.first?.label == "New Addr")
    }

    @Test func newestTombstoneSuppressesOlderLiveRecordForSameFingerprint() {
        let live = #"{"v": 1, "label": "Live", "host": "10.0.0.1", "port": 1, "#
            + #""fingerprint": "aa", "updatedAt": 100}"#
        let tombstone = #"{"v": 1, "label": "Dead", "host": "10.0.0.2", "port": 2, "#
            + #""fingerprint": "aa", "updatedAt": 200, "deleted": true}"#
        let keychain = FakeSyncedKeychain(outcome: .rows([
            row(account: "10.0.0.1:1", payload: live),
            row(account: "10.0.0.2:2", payload: tombstone),
        ]))
        #expect(registry(keychain).listLiveBackends() == .available([]))
    }

    @Test func newerLiveRecordSurvivesOlderTombstoneForSameFingerprint() {
        let tombstone = #"{"v": 1, "label": "Dead", "host": "10.0.0.1", "port": 1, "#
            + #""fingerprint": "aa", "updatedAt": 100, "deleted": true}"#
        let live = #"{"v": 1, "label": "Back", "host": "10.0.0.2", "port": 2, "#
            + #""fingerprint": "aa", "updatedAt": 200}"#
        let keychain = FakeSyncedKeychain(outcome: .rows([
            row(account: "10.0.0.1:1", payload: tombstone),
            row(account: "10.0.0.2:2", payload: live),
        ]))
        guard case .available(let records) = registry(keychain).listLiveBackends() else {
            Issue.record("expected .available")
            return
        }
        #expect(records.count == 1)
        #expect(records.first?.label == "Back")
    }

    @Test func equalClockTombstoneWinsRegardlessOfRowOrder() {
        let live = #"{"v": 1, "label": "Live", "host": "10.0.0.1", "port": 1, "#
            + #""fingerprint": "aa", "updatedAt": 100}"#
        let tombstone = #"{"v": 1, "label": "Dead", "host": "10.0.0.2", "port": 2, "#
            + #""fingerprint": "aa", "updatedAt": 100, "deleted": true}"#
        let liveFirst = FakeSyncedKeychain(outcome: .rows([
            row(account: "10.0.0.1:1", payload: live),
            row(account: "10.0.0.2:2", payload: tombstone),
        ]))
        let tombstoneFirst = FakeSyncedKeychain(outcome: .rows([
            row(account: "10.0.0.2:2", payload: tombstone),
            row(account: "10.0.0.1:1", payload: live),
        ]))
        #expect(registry(liveFirst).listLiveBackends() == .available([]))
        #expect(registry(tombstoneFirst).listLiveBackends() == .available([]))
    }

    @Test func equalClockLiveTieBreaksByAccountKeyRegardlessOfRowOrder() {
        let smaller = #"{"v": 1, "label": "Smaller", "host": "10.0.0.1", "port": 1, "#
            + #""fingerprint": "aa", "updatedAt": 100}"#
        let larger = #"{"v": 1, "label": "Larger", "host": "10.0.0.2", "port": 2, "#
            + #""fingerprint": "aa", "updatedAt": 100}"#
        for rows in [
            [row(account: "10.0.0.1:1", payload: smaller), row(account: "10.0.0.2:2", payload: larger)],
            [row(account: "10.0.0.2:2", payload: larger), row(account: "10.0.0.1:1", payload: smaller)],
        ] {
            let keychain = FakeSyncedKeychain(outcome: .rows(rows))
            guard case .available(let records) = registry(keychain).listLiveBackends() else {
                Issue.record("expected .available")
                return
            }
            #expect(records.map(\.label) == ["Larger"])
        }
    }

    @Test func accountTieBreakNormalizesHostCaseAndWhitespace() {
        let smaller = #"{"v": 1, "label": "Smaller", "host": " MAC-A.local ", "port": 1, "#
            + #""fingerprint": "aa", "updatedAt": 100}"#
        let larger = #"{"v": 1, "label": "Larger", "host": "mac-b.local", "port": 1, "#
            + #""fingerprint": "aa", "updatedAt": 100}"#
        let keychain = FakeSyncedKeychain(outcome: .rows([
            row(account: "mac-b.local:1", payload: larger),
            row(account: "mac-a.local:1", payload: smaller),
        ]))
        guard case .available(let records) = registry(keychain).listLiveBackends() else {
            Issue.record("expected .available")
            return
        }
        #expect(records.map(\.label) == ["Larger"])
    }

    @Test func blankFingerprintsKeyByHostPort() {
        let a = #"{"v": 1, "label": "A", "host": "10.0.0.1", "port": 1, "#
            + #""fingerprint": "", "updatedAt": 100}"#
        let b = #"{"v": 1, "label": "B", "host": "10.0.0.2", "port": 2, "#
            + #""fingerprint": "", "updatedAt": 100}"#
        let keychain = FakeSyncedKeychain(outcome: .rows([
            row(account: "10.0.0.1:1", payload: a),
            row(account: "10.0.0.2:2", payload: b),
        ]))
        guard case .available(let records) = registry(keychain).listLiveBackends() else {
            Issue.record("expected .available")
            return
        }
        #expect(records.map(\.label) == ["A", "B"])
    }
}
