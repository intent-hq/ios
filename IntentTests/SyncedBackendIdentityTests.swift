@testable import Intent
import Testing

// MARK: - Identity keys + access group

struct SyncedBackendIdentityTests {
    private func record(fingerprint: String, host: String = "H", port: Int = 1)
        -> SyncedBackendRecord {
        SyncedBackendRecord(
            label: "L",
            host: host,
            hosts: [host],
            port: port,
            fingerprint: fingerprint,
            hostname: nil,
            detectHosts: true,
            token: "",
            updatedAt: 0,
            deleted: false,
            deletedAt: nil
        )
    }

    @Test func registryKeyNormalizesFingerprint() {
        #expect(record(fingerprint: "  ab:cd ").registryKey == "fp:AB:CD")
    }

    @Test func registryKeyFallsBackToNormalizedHostPort() {
        #expect(
            record(fingerprint: "   ", host: " Mac.Local ", port: 88).registryKey
                == "addr:mac.local:88"
        )
    }

    @Test func sharedAccessGroupRequiresPrefix() {
        #expect(SyncedBackendRegistry.sharedAccessGroup(appIdentifierPrefix: nil) == nil)
        #expect(SyncedBackendRegistry.sharedAccessGroup(appIdentifierPrefix: "") == nil)
        #expect(SyncedBackendRegistry.sharedAccessGroup(appIdentifierPrefix: "  ") == nil)
    }

    @Test func sharedAccessGroupJoinsPrefixAndSuffix() {
        #expect(
            SyncedBackendRegistry.sharedAccessGroup(appIdentifierPrefix: "TEAM123.")
                == "TEAM123.dev.intentapp.backends"
        )
        #expect(
            SyncedBackendRegistry.sharedAccessGroup(appIdentifierPrefix: "TEAM123")
                == "TEAM123.dev.intentapp.backends"
        )
    }
}
