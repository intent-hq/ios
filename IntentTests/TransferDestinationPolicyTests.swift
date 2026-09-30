import Foundation
@testable import Intent
import Testing

struct TransferDestinationPolicyTests {
    @Test func excludesSourceAliasesAndKnownNonOwners() {
        let source = connection(pin: "ABCD", role: .owner)
        let alias = connection(pin: "abcd", role: .owner)
        let member = connection(pin: "member", role: .member)
        let guest = connection(pin: "guest", role: .guest)
        let target = connection(pin: "target", role: .owner)
        let legacy = connection(pin: "legacy", role: nil)

        let destinations = WorkspaceTransferDestinationPolicy.destinations(
            from: [source, alias, member, guest, target, legacy], sourceID: source.id
        )

        #expect(destinations.map(\.id) == [target.id, legacy.id])
    }

    @Test func missingPinsDoNotHideOtherMachines() {
        let source = connection(pin: nil, role: .owner)
        let target = connection(pin: nil, role: .owner)
        #expect(WorkspaceTransferDestinationPolicy.destinations(
            from: [source, target], sourceID: source.id
        ).map(\.id) == [target.id])
    }

    private func connection(pin: String?, role: ConnectionPrincipal.HostRole?) -> StoredConnection {
        var connection = StoredConnection(
            server: PairedServer(
                hosts: ["localhost"], port: 8080, name: "Machine", pairedAt: .distantPast, certFingerprint: pin
            ),
            token: "test-token"
        )
        connection.principal = role.map {
            ConnectionPrincipal(id: "test-owner", hostRole: $0, revision: nil, login: nil, displayName: nil)
        }
        return connection
    }
}
