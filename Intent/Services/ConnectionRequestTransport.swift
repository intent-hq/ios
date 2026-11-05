import Foundation

/// An in-process stand-in for the daemon socket. When a connection holds one,
/// `ConnectionManager.request` asks it for every response instead of writing
/// JSON-RPC to a socket; it also supplies the identity and capabilities a
/// daemon handshake would otherwise provide.
@MainActor
protocol ConnectionRequestTransport: AnyObject {
    /// Stands in for the admitted principal; nil defers to the handshake.
    var principal: ConnectionPrincipal? { get }
    var capabilities: ConnectionCapabilities { get }

    func response(for method: String, params: [String: Any], on connection: ConnectionManager) async throws -> Any
    /// Called when the connection replaces or drops this transport.
    func stop()
}

extension ConnectionManager {
    /// The single Debug seam that chooses an in-process transport. Debug demo
    /// launches get the fixture transport; Release has no demo types and
    /// always uses the socket.
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
