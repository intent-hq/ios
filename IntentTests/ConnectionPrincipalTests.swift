import Foundation
@testable import Intent
import Testing

struct ConnectionPrincipalTests {
    private let hello: [String: Any] = ["server": ["capabilities": ["hostMembership": 1]]]

    @Test(arguments: ["owner", "member", "guest"])
    func authoritativeRolesAreTruthful(_ role: String) throws {
        let principal = try ConnectionPrincipal.parse([
            "id": "person", "hostRole": role, "hostMembershipRevision": 7, "isAdministrator": role == "owner"
        ], hello: hello)
        #expect(principal.isOwner == (role == "owner"))
        #expect(principal.canManageWorkspaces == (role != "guest"))
    }

    @Test func malformedCurrentAuthorityFailsClosed() {
        let cases: [[String: Any]] = [
            ["id": "B", "isAdministrator": false],
            ["id": "B", "isAdministrator": false, "hostRole": "owner", "hostMembershipRevision": 1],
            ["id": "B", "isAdministrator": 1, "hostRole": "owner", "hostMembershipRevision": 1],
            ["id": "B", "isAdministrator": false, "hostRole": "member", "hostMembershipRevision": true],
            ["id": "", "isAdministrator": true, "hostRole": "owner", "hostMembershipRevision": 1],
            ["id": "B", "isAdministrator": false, "hostRole": "future", "hostMembershipRevision": 1]
        ]
        for row in cases {
            #expect(throws: (any Error).self) { try ConnectionPrincipal.parse(row, hello: hello) }
        }
    }

    @Test func legacyAuthorityNeverInfersMembership() throws {
        let legacy: [String: Any] = ["server": ["capabilities": [String: Int]()]]
        #expect(try ConnectionPrincipal.parse(["id": "A", "isAdministrator": true], hello: legacy).isOwner)
        #expect(try ConnectionPrincipal.parse(["id": "B", "isAdministrator": false], hello: legacy).hostRole == .guest)
        #expect(throws: (any Error).self) {
            try ConnectionPrincipal.parse(["id": "B", "isAdministrator": false, "hostRole": "member"], hello: legacy)
        }
    }

    @Test func onlyAuthoritativeRevocationCreatesRemovalEvidence() {
        #expect(ConnectionPrincipal.isRevocation(WebSocketTransportError.disconnected(host: "test", code: 4001, reason: "credential revoked")))
        #expect(!ConnectionPrincipal.isRevocation(WebSocketTransportError.disconnected(host: "test", code: 1006, reason: "credential revoked")))
        #expect(!ConnectionPrincipal.isRevocation(WebSocketTransportError.disconnected(host: "test", code: 4001, reason: "other")))
        #expect(!ConnectionPrincipal.isRevocation(URLError(.notConnectedToInternet)))
    }

    @Test @MainActor func deviceIDsSurviveRelaunchAndRemainSeparateFromPeople() throws {
        let firstSuite = "ClientIdentity-\(UUID().uuidString)"
        let secondSuite = "ClientIdentity-\(UUID().uuidString)"
        let first = try #require(UserDefaults(suiteName: firstSuite))
        let second = try #require(UserDefaults(suiteName: secondSuite))
        defer {
            first.removePersistentDomain(forName: firstSuite)
            second.removePersistentDomain(forName: secondSuite)
        }
        let id = PairingClientIdentity.identifier(defaults: first)
        #expect(PairingClientIdentity.identifier(defaults: first) == id)
        #expect(PairingClientIdentity.identifier(defaults: second) != id)
        let recreated = try #require(UserDefaults(suiteName: firstSuite))
        let hello = PairingClientIdentity.parameters(defaults: recreated)
        #expect(hello["clientId"] as? String == id)
        #expect(hello["principalId"] == nil)
        #expect(hello["hostRole"] == nil)
        #expect(hello["token"] == nil)
    }
}
