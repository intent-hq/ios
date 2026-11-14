import Network

extension NWListener {
    /// A test server's listener on 127.0.0.1 only (ios#981). A listener on `.any` is dual-stack, and
    /// macOS then lets another process bind 127.0.0.1 on the same port with SO_REUSEADDR: that process
    /// receives the test's connections to 127.0.0.1 and answers with its own status, such as HTTP 401.
    nonisolated static func loopback(using parameters: NWParameters = .tcp) throws -> NWListener {
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        return try NWListener(using: parameters)
    }
}
