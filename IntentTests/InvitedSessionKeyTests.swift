import Foundation
@testable import Intent
import Testing

struct InvitedSessionKeyTests {
    @Test func matchesIndependentlyDerivedUTF8Vectors() throws {
        let url = try TestSourceInputs.url(for: "IntentTests/Fixtures/invited-session-v2.json")
        let data = try Data(contentsOf: url)
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(fixture["feCommit"] as? String == "25bf2bbd5d36459d202d84b4d18917a8ab5f4c24")
        let pin = try #require(fixture["fingerprint"] as? String)
        let vectors = try #require(fixture["sessions"] as? [[String: String]])
        #expect(vectors.count == 10)
        for vector in vectors {
            let principal = try #require(vector["principalId"])
            #expect(principal.utf8.map { String(format: "%02x", $0) }.joined() == vector["utf8Hex"])
            #expect(try InvitedSyncKey.session(fingerprint: pin, principalId: principal) == vector["account"])
        }
        let removal = try #require(fixture["removal"] as? [String: Any])
        #expect(try InvitedSyncKey.removal(
            fingerprint: pin,
            principalId: "B",
            removalId: "00000000-0000-4000-8000-000000000001",
            removedThrough: 200,
            legacyAccounts: ["old.example:443"]
        ) == removal["account"] as? String)
    }

    @Test func neverNormalizesOpaquePrincipalsOrUTF8Ordering() throws {
        let pin = InvitedSessionFixtures.pin
        #expect(try InvitedSyncKey.session(fingerprint: pin, principalId: "é") != InvitedSyncKey.session(fingerprint: pin, principalId: "e\u{301}"))
        #expect(!ConnectionPrincipal.samePerson("é", "e\u{301}"))
        #expect(InvitedSyncKey.sorted(["é", "e\u{301}", "é"]).count == 2)
        #expect(InvitedSyncKey.sorted(["\u{10000}", "\u{E000}"]) == ["\u{E000}", "\u{10000}"])
        #expect(try InvitedSyncKey.fingerprint(Array(repeating: "AB", count: 32).joined(separator: ":")) == pin)
    }

    @Test(arguments: ["", "ab:cd", String(repeating: "gg", count: 32), String(repeating: "ab", count: 31), " " + InvitedSessionFixtures.pin])
    func rejectsInvalidPins(_ pin: String) {
        #expect(throws: (any Error).self) { try InvitedSyncKey.session(fingerprint: pin, principalId: "B") }
    }

    @Test func ownerV1RejectsInvitedV2WithoutLearningIdentity() throws {
        let record = try InvitedSessionFixtures.session()
        let data = try #require(record.data)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(SyncedBackendPayload.parse(text) == .newerVersion)
        #expect(record.account.hasPrefix("invited-v2-s:"))
        #expect(!record.account.contains(record.fingerprint))
    }
}
