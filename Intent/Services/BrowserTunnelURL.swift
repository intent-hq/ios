import Foundation

/// Only explicit daemon-loopback names are forwarded; arbitrary DNS names never
/// gain access to the tunnel. No daemon bearer token appears in the browser URL.
nonisolated enum BrowserTunnelURL {
    private static let daemonHosts: Set<String> = [
        "daemon.localhost", "localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"
    ]
    private static let httpPort = 80
    private static let httpsPort = 443

    static func remotePort(for url: URL, localPorts: Set<UInt16> = []) throws -> UInt16? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil else {
            throw BrowserTunnelError.invalidURL
        }
        guard daemonHosts.contains(host) else { return nil }
        let port = components.port ?? (scheme == "https" ? httpsPort : httpPort)
        guard let port = UInt16(exactly: port), port != 0 else { throw BrowserTunnelError.invalidURL }
        // Only the exact address emitted by rewrite is our own listener. A
        // daemon.localhost URL on the same numeric port still names the daemon.
        if host == "127.0.0.1", localPorts.contains(port) { return nil }
        return port
    }

    static func rewrite(_ url: URL, localPort: UInt16) throws -> URL {
        guard localPort != 0,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw BrowserTunnelError.invalidURL
        }
        components.host = "127.0.0.1"
        components.port = Int(localPort)
        guard let rewritten = components.url else { throw BrowserTunnelError.invalidURL }
        return rewritten
    }
}
