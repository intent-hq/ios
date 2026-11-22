import Network

extension NWListener {
    nonisolated static func loopback(using parameters: NWParameters = .tcp) throws -> NWListener {
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        return try NWListener(using: parameters)
    }
}
