import Combine
import Foundation

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
}

/// The subset of ConnectionManager surface that subscribe-channel stores depend on.
/// Exists to allow tests to inject a fake; ConnectionManager conforms as-is.
@MainActor
protocol ConnectionManagerRouting: AnyObject {
    var connectionState: ConnectionState { get }
    var connectionStatePublisher: AnyPublisher<ConnectionState, Never> { get }
    func request(_ method: String, params: [String: Any], timeout: TimeInterval) async throws -> Any
    @discardableResult func onEvent(_ handler: @escaping (String, Any) -> Void) -> UUID
    func removeEventHandler(id: UUID)
    func registerSubscriptionHandler(id: String, handler: @escaping @MainActor (SubscriptionPush) -> Void)
    func unregisterSubscriptionHandler(id: String)
}

extension ConnectionManagerRouting {
    func request(_ method: String) async throws -> Any {
        try await request(method, params: [:], timeout: ConnectionManager.defaultRequestTimeout)
    }

    func request(_ method: String, params: [String: Any]) async throws -> Any {
        try await request(method, params: params, timeout: ConnectionManager.defaultRequestTimeout)
    }
}

nonisolated extension NSError {
    /// userInfo key carrying the JSON-RPC `error.data.code` discriminator (PROTOCOL §3.3).
    static let intentErrorDataCodeKey = "intentErrorDataCode"

    /// The JSON-RPC `error.data.code` discriminator attached by the daemon, if any.
    var intentErrorDataCode: String? {
        userInfo[NSError.intentErrorDataCodeKey] as? String
    }

    /// True only for a definitive entity-not-found JSON-RPC error.
    var isEntityNotFound: Bool {
        domain == "WebSocket" && code == -32602 && intentErrorDataCode == "not-found"
    }
}