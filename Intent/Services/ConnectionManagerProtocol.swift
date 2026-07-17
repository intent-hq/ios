import Foundation
import Combine

/// Protocol seam for ConnectionManager to enable testing.
/// Stores use this subset of ConnectionManager's API for subscribe-channel integration.
@MainActor
protocol ConnectionManagerProtocol {
    /// Connection state publisher for observing connect/disconnect events
    var connectionState: ConnectionState { get }
    var connectionStatePublisher: Published<ConnectionState>.Publisher { get }
    
    /// Send a JSON-RPC request and await response
    func request(_ method: String, params: [String: Any]) async throws -> Any
    
    /// Register an event handler for all incoming events (notifications + subscription.push)
    @discardableResult
    func onEvent(_ handler: @escaping (String, Any) -> Void) -> UUID
    
    /// Unregister an event handler by ID
    func removeEventHandler(id: UUID)
}

/// Extension to make ConnectionManager conform to the protocol
extension ConnectionManager: ConnectionManagerProtocol {
    var connectionStatePublisher: Published<ConnectionState>.Publisher {
        $connectionState
    }
}
