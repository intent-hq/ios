import Combine
import Foundation

enum ConnectionState: Equatable {
    case connected
    case connecting
    case disconnected
    case reconnecting(attempt: Int)
}

/// How a store reacts to one bus event type (or one discriminating payload
/// value of it). Each store exposes a pure `classify(type:data:)` returning
/// `nil` for anything its tables do not name, so the coverage test in
/// `IntentTests/EventCatalogCoverageTests.swift` can prove every type intentd
/// emits on the store's channels is a deliberate decision.
nonisolated enum EventClassification: Equatable, Sendable {
    /// Deliberately dropped: no rendered field depends on it.
    case ignore
    /// Apply the payload to the row in place; no refetch.
    case patchInPlace
    /// Refetch the store's list (non-live fallback only).
    case refetch
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
    private static let jsonRPCInvalidParametersErrorCode = -32_602
    private static let webSocketErrorDomain = "WebSocket"

    /// userInfo key carrying the JSON-RPC `error.data.code` discriminator (PROTOCOL §3.3).
    static let intentErrorDataCodeKey = "intentErrorDataCode"

    /// The JSON-RPC `error.data.code` discriminator attached by the daemon, if any.
    var intentErrorDataCode: String? {
        userInfo[Self.intentErrorDataCodeKey] as? String
    }

    /// True only for a definitive entity-not-found JSON-RPC error.
    var isEntityNotFound: Bool {
        domain == Self.webSocketErrorDomain
            && code == Self.jsonRPCInvalidParametersErrorCode
            && intentErrorDataCode == "not-found"
    }
}
