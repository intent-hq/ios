import Foundation
import Security
import Testing

@testable import Intent

/// `role: "node"` records describe agent runners that iOS cannot connect to:
/// the registry hides live nodes, keeps node tombstones, and treats a
/// missing or unknown role as today's connectable backend.

private func row(account: String, payload: String) -> [String: Any] {
    [
        kSecAttrAccount as String: account,
        kSecValueData as String: Data(payload.utf8)
    ]
}

// MARK: - Payload parsing

struct SyncedBackendRolePayloadTests {
    @Test func parsesNodeRole() {
        let payload = """
            {"v": 1, "label": "Runner", "host": "10.0.0.3", "port": 1, \
            "fingerprint": "ff", "updatedAt": 5, "role": "node"}
            """
        guard case .record(let record) = SyncedBackendPayload.parse(payload) else {
            Issue.record("expected .record")
            return
        }
        #expect(record.role == "node")
        #expect(record.isNode)
    }

    @Test(arguments: [
        #""role": null"#, #""role": "  ""#, #""role": 1"#, #""role": true"#, #""someOtherField": 1"#
    ])
    func missingOrNonStringRoleIsNoRole(field: String) {
        let payload = #"{"v": 1, "label": "L", "host": "h", "port": 1, "fingerprint": "f", "updatedAt": 5, "#
            + field + "}"
        guard case .record(let record) = SyncedBackendPayload.parse(payload) else {
            Issue.record("expected .record for \(field)")
            return
        }
        #expect(record.role == nil)
        #expect(!record.isNode)
    }

    @Test func unknownRoleIsKeptButNotANode() {
        let payload = #"{"v": 1, "label": "L", "host": "h", "port": 1, "fingerprint": "f", "#
            + #""updatedAt": 5, "role": "relay"}"#
        guard case .record(let record) = SyncedBackendPayload.parse(payload) else {
            Issue.record("expected .record")
            return
        }
        #expect(record.role == "relay")
        #expect(!record.isNode)
    }
}

// MARK: - Registry list

struct SyncedBackendNodeRecordTests {
    private let now = Date(timeIntervalSince1970: 1)

    private func registry(_ keychain: FakeSyncedKeychain) -> SyncedBackendRegistry {
        SyncedBackendRegistry(keychain: keychain, accessGroup: "T.dev.intentapp.backends")
    }

    @Test func nodeRecordsAreHiddenAndOtherRecordsAreUnaffected() {
        let backend = #"{"v": 1, "label": "Backend", "host": "10.0.0.1", "port": 1, "#
            + #""fingerprint": "aa", "updatedAt": 100}"#
        let explicitBackend = #"{"v": 1, "label": "Explicit", "host": "10.0.0.4", "port": 4, "#
            + #""fingerprint": "dd", "updatedAt": 100, "role": "backend"}"#
        let node = #"{"v": 1, "label": "Node", "host": "10.0.0.2", "port": 2, "#
            + #""fingerprint": "bb", "updatedAt": 100, "role": "node"}"#
        let unknown = #"{"v": 1, "label": "Unknown", "host": "10.0.0.3", "port": 3, "#
            + #""fingerprint": "cc", "updatedAt": 100, "role": "relay"}"#
        let keychain = FakeSyncedKeychain(outcome: .rows([
            row(account: "10.0.0.1:1", payload: backend),
            row(account: "10.0.0.2:2", payload: node),
            row(account: "10.0.0.3:3", payload: unknown),
            row(account: "10.0.0.4:4", payload: explicitBackend)
        ]))
        guard case .available(let all) = registry(keychain).listBackends(now: now),
            case .available(let live) = registry(keychain).listLiveBackends(now: now)
        else {
            Issue.record("expected .available")
            return
        }
        #expect(all.map(\.label) == ["Backend", "Unknown", "Explicit"])
        #expect(live.map(\.label) == ["Backend", "Unknown", "Explicit"])
    }

    @Test func registryOfOnlyNodesIsEmptyNotUnavailable() {
        let node = #"{"v": 1, "label": "Node", "host": "10.0.0.2", "port": 2, "#
            + #""fingerprint": "bb", "updatedAt": 100, "role": "node"}"#
        let keychain = FakeSyncedKeychain(outcome: .rows([row(account: "10.0.0.2:2", payload: node)]))
        #expect(registry(keychain).listBackends(now: now) == .available([]))
        #expect(registry(keychain).listLiveBackends(now: now) == .available([]))
    }

    @Test func nodeTombstonesAreStillListed() {
        let tombstone = #"{"v": 1, "label": "Dead Node", "host": "10.0.0.2", "port": 2, "#
            + #""fingerprint": "bb", "updatedAt": 200, "deleted": true, "role": "node"}"#
        let keychain = FakeSyncedKeychain(outcome: .rows([row(account: "10.0.0.2:2", payload: tombstone)]))
        guard case .available(let records) = registry(keychain).listBackends(now: now) else {
            Issue.record("expected .available")
            return
        }
        #expect(records.map(\.label) == ["Dead Node"])
        #expect(records.map(\.deleted) == [true])
    }

    @Test func newerNodeRecordHidesOlderBackendCopyRegardlessOfRowOrder() {
        // A machine re-published as a node must not resurface through an
        // older backend copy of the same identity.
        let backend = #"{"v": 1, "label": "Backend", "host": "10.0.0.1", "port": 1, "#
            + #""fingerprint": "aa", "updatedAt": 100}"#
        let node = #"{"v": 1, "label": "Node", "host": "10.0.0.2", "port": 2, "#
            + #""fingerprint": "aa", "updatedAt": 200, "role": "node"}"#
        for rows in [
            [row(account: "10.0.0.1:1", payload: backend), row(account: "10.0.0.2:2", payload: node)],
            [row(account: "10.0.0.2:2", payload: node), row(account: "10.0.0.1:1", payload: backend)]
        ] {
            let keychain = FakeSyncedKeychain(outcome: .rows(rows))
            #expect(registry(keychain).listBackends(now: now) == .available([]))
        }
    }

    @Test func newerBackendRecordSurvivesOlderNodeCopy() {
        let node = #"{"v": 1, "label": "Node", "host": "10.0.0.2", "port": 2, "#
            + #""fingerprint": "aa", "updatedAt": 100, "role": "node"}"#
        let backend = #"{"v": 1, "label": "Backend", "host": "10.0.0.1", "port": 1, "#
            + #""fingerprint": "aa", "updatedAt": 200}"#
        let keychain = FakeSyncedKeychain(outcome: .rows([
            row(account: "10.0.0.2:2", payload: node),
            row(account: "10.0.0.1:1", payload: backend)
        ]))
        guard case .available(let records) = registry(keychain).listBackends(now: now) else {
            Issue.record("expected .available")
            return
        }
        #expect(records.map(\.label) == ["Backend"])
    }
}
