import Foundation
@testable import Intent
import Network
import Testing

// Explicit ports and encoded URL fixtures exercise the wire/security contract.
// swiftlint:disable no_magic_numbers
@MainActor
struct BrowserTunnelURLTests {
    @Test func recognizesOnlyExplicitDaemonLoopbackHosts() throws {
        for host in ["localhost", "LOCALHOST", "127.0.0.1", "[::1]", "daemon.localhost", "0.0.0.0"] {
            let url = try #require(URL(string: "http://\(host):5173/"))
            #expect(try BrowserTunnelURL.remotePort(for: url) == 5173)
        }
        for host in ["example.com", "localhost.evil.test", "daemon.localhost.evil.test", "192.168.1.20"] {
            let url = try #require(URL(string: "http://\(host):5173/"))
            #expect(try BrowserTunnelURL.remotePort(for: url) == nil)
        }
    }

    @Test func preservesSchemeAndExactEscapedURLComponents() throws {
        let url = try #require(URL(string: "https://daemon.localhost:8443/a%2Fb?q=a%26b&x=%2F#part%202"))
        let result = try BrowserTunnelURL.rewrite(url, localPort: 49152)
        #expect(result.absoluteString == "https://127.0.0.1:49152/a%2Fb?q=a%26b&x=%2F#part%202")
        #expect(try BrowserTunnelURL.remotePort(for: result, localPorts: [49152]) == nil)
        #expect(try BrowserTunnelURL.remotePort(for: url, localPorts: [8443]) == 8443)
    }

    @Test func handlesDefaultPortsAndRejectsCredentialsAndUnsafeSchemes() throws {
        #expect(try BrowserTunnelURL.remotePort(for: #require(URL(string: "http://localhost"))) == 80)
        #expect(try BrowserTunnelURL.remotePort(for: #require(URL(string: "https://localhost"))) == 443)
        for raw in ["file:///tmp/a", "javascript:alert(1)", "ftp://localhost:21", "http://localhost:0", "http://localhost:65536", "http://user:secret@localhost"] {
            let url = try #require(URL(string: raw))
            #expect(throws: BrowserTunnelError.invalidURL) { try BrowserTunnelURL.remotePort(for: url) }
        }
    }

    @Test func tunnelEndpointPreservesPinnedSecurityAndHeaderCredentials() throws {
        for fingerprint in [nil, "", " \n"] as [String?] {
            #expect(throws: WebSocketTransportError.self) {
                try WebSocketConnection.makeURL(host: "daemon.example", port: 5181, certFingerprint: fingerprint, endpoint: .tunnel)
            }
        }
        let url = try WebSocketConnection.makeURL(host: "daemon.example", port: 5181, certFingerprint: "AA:BB", endpoint: .tunnel)
        #expect(url.absoluteString == "wss://daemon.example:5181/tunnel")
        #expect(url.query == nil)
        #expect(url.user == nil)
        #expect(WebSocketConnection.additionalHeaders(token: "secret").first?.value == "Bearer secret")
        #expect(try WebSocketConnection.makeURL(host: "daemon.example", port: 5181, certFingerprint: "AA:BB").path == "/ws")
        #expect(WebSocketConnection.Endpoint.tunnel.maximumMessageSize == BrowserTunnelFrame.maximumMessageSize)
        #expect(WebSocketConnection.Endpoint.rpc.maximumMessageSize == 40 * 1024 * 1024)
    }

    @Test func webSocketHostCannotInjectPathOrCredentials() {
        for host in ["daemon.example/tunnel", "user@daemon.example", "daemon.example?x=y", "daemon.example#fragment", "daemon.example\\path"] {
            #expect(throws: WebSocketTransportError.self) {
                try WebSocketConnection.makeURL(host: host, port: 5181, certFingerprint: "AA:BB", endpoint: .tunnel)
            }
        }
    }

    @Test func listenerBindsOnlyIPv4Loopback() throws {
        let endpoint = try #require(BrowserTunnelListener.parameters().requiredLocalEndpoint)
        guard case let .hostPort(host, port) = endpoint else {
            Issue.record("Expected an explicit loopback host and ephemeral port")
            return
        }
        #expect(host == BrowserTunnelListener.loopbackHost)
        #expect(port == .any)
    }
}
// swiftlint:enable no_magic_numbers
