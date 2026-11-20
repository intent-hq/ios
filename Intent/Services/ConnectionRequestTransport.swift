import Foundation

@MainActor
protocol ConnectionRequestTransport: AnyObject {
    var principal: ConnectionPrincipal? { get }
    var capabilities: ConnectionCapabilities { get }

    func response(for method: String, params: [String: Any], on connection: ConnectionManager) async throws -> Any
    func stop()
}

extension ConnectionManager {
    static func makeInProcessTransport(
        serveFixtures: Bool,
        arguments: [String] = LaunchOptions.current.arguments
    ) -> (any ConnectionRequestTransport)? {
        #if DEBUG
        DemoConnectionTransport.make(serveFixtures: serveFixtures, arguments: arguments)
        #else
        nil
        #endif
    }
}
