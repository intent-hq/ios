import Foundation
@testable import Intent
import Testing

@MainActor struct InvitedSessionMergeTests {
    @Test func credentialRouteAndMetadataClocksAreIndependent() throws {
        let newestCredential = try InvitedSessionFixtures.session(changes: ["pairedAt": 400, "updatedAt": 400, "token": "rotated", "extensionA": ["keep": true]])
        let newestRoute = try InvitedSessionFixtures.session(changes: ["updatedAt": 600, "tcAddress": "tcNew", "tcUpdatedAt": 500, "extensionB": "keep"])
        let hostOnly = try InvitedSessionFixtures.session(changes: ["updatedAt": 900, "label": "New name"])
        let merged = try #require(InvitedSyncMerge.person([newestCredential, newestRoute, hostOnly]))
        #expect(merged.token == "rotated")
        #expect(merged.pairedAt == 400)
        #expect(merged.object["label"] as? String == "New name")
        #expect(merged.object["tcAddress"] as? String == "tcNew")
        #expect(merged.object["extensionA"] as? [String: Bool] == ["keep": true])
        #expect(merged.object["extensionB"] as? String == "keep")
        let clear = try InvitedSessionFixtures.session(changes: ["tcAddress": NSNull(), "tcUpdatedAt": 500])
        #expect(InvitedSyncMerge.person([newestRoute, clear])?.object["tcAddress"] is NSNull)
        #expect(InvitedSyncMerge.person([clear, newestRoute])?.object["tcAddress"] is NSNull)
    }

    @Test func removalCannotCrossPersonAndPreservesExtensionsAfterCompaction() throws {
        let live = try InvitedSessionFixtures.session(changes: ["unknown": "kept"])
        let removal = try InvitedSessionFixtures.removal()
        let compact = try #require(InvitedSyncMerge.person([live, removal]))
        #expect(compact.kind == "removed")
        #expect(compact.token.isEmpty)
        #expect(compact.object["unknown"] as? String == "kept")
        #expect(compact.object["login"] == nil)
        #expect(compact.object["tcAddress"] == nil)
        #expect(try InvitedSyncMerge.person([InvitedSessionFixtures.session("C"), removal]) == nil)
    }

    @Test func futureAndMalformedPayloadsFreezeRatherThanCoerce() throws {
        let base = try InvitedSessionFixtures.session()
        let invalid: [[String: Any]] = [
            ["v": true], ["v": 3], ["pairedAt": true], ["removedThrough": -1], ["port": 1.5],
            ["accent": "purple"], ["deviceIcon": "phone"], ["detectedDeviceKind": "mac"],
            ["legacyAccounts": ["z:443", "a:443"]], ["deleted": 1], ["token": ""]
        ]
        for patch in invalid {
            let object = base.object.merging(patch) { _, new in new }
            #expect(InvitedSyncRecord.parse(account: base.account, data: try JSONSerialization.data(withJSONObject: object)) == nil)
        }
        let removal = try InvitedSessionFixtures.removal()
        for field in ["token", "login", "hostRole", "tcAddress"] {
            var object = removal.object
            object[field] = "should-not-leak"
            #expect(InvitedSyncRecord.parse(account: removal.account, data: try JSONSerialization.data(withJSONObject: object)) == nil)
        }
    }
}
