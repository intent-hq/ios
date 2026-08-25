import Foundation
import Testing
@testable import Intent

/// Tests for the connection display-name selection from a `host.status` result:
/// prettyHostname > hostname > nil (caller falls back to host:port).
struct ConnectionPairingTests {

    @Test func prefersPrettyHostnameOverHostname() {
        let status: [String: Any] = [
            "prettyHostname": "Clement's Mac Studio",
            "hostname": "ClementacStudio.local-domain",
        ]
        #expect(ConnectionPairing.displayName(fromHostStatus: status) == "Clement's Mac Studio")
    }

    @Test func fallsBackToHostnameWhenPrettyHostnameAbsent() {
        let status: [String: Any] = ["hostname": "studio.local"]
        #expect(ConnectionPairing.displayName(fromHostStatus: status) == "studio.local")
    }

    @Test func fallsBackToHostnameWhenPrettyHostnameEmpty() {
        let status: [String: Any] = ["prettyHostname": "", "hostname": "studio.local"]
        #expect(ConnectionPairing.displayName(fromHostStatus: status) == "studio.local")
    }

    @Test func returnsNilWhenBothAbsent() {
        #expect(ConnectionPairing.displayName(fromHostStatus: [String: Any]()) == nil)
    }

    @Test func returnsNilWhenBothEmpty() {
        let status: [String: Any] = ["prettyHostname": "", "hostname": ""]
        #expect(ConnectionPairing.displayName(fromHostStatus: status) == nil)
    }

    @Test func returnsNilForNonDictionaryResult() {
        #expect(ConnectionPairing.displayName(fromHostStatus: "not a dict") == nil)
    }

    @Test func nilSelectionFallsBackToHostPortInStoredConnection() {
        let server = PairedServer(
            hosts: ["10.0.0.1"], port: 4242, name: "Intent", pairedAt: Date())
        let stored = StoredConnection(server: server, token: "tok", displayName: nil)
        #expect(stored.displayName == "10.0.0.1:4242")
    }
}
