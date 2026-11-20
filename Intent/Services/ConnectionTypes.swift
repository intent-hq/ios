import Combine
import Foundation

enum ConnectionState: Equatable {
    case connected
    case connecting
    case disconnected
    case reconnecting(attempt: Int)
}

nonisolated enum InboundFrame: Sendable {
    case error(id: Int, error: NSError)
    case notification(method: String, params: InboundJSONValue)
    case response(id: Int, result: InboundJSONValue)
    case subscriptionPush(SubscriptionPush)

    var label: String {
        switch self {
        case let .response(id, _), let .error(id, _): "id=\(id)"
        case .subscriptionPush: "method=subscription.push"
        case let .notification(method, _): "method=\(method)"
        }
    }
}

nonisolated enum EventClassification: Equatable, Sendable {
    case ignore
    case patchInPlace
    case refetch
}

@MainActor
protocol ConnectionManagerRouting: AnyObject {
    var connectionState: ConnectionState { get }
    var connectionStatePublisher: AnyPublisher<ConnectionState, Never> { get }
    var capabilities: ConnectionCapabilities { get }
    var capabilitiesPublisher: AnyPublisher<ConnectionCapabilities, Never> { get }

    func disableScriptMonitors()

    var globalSubscriptionState: ConnectionManager.GlobalSubscriptionState { get }
    var globalSubscriptionPublisher: AnyPublisher<ConnectionManager.GlobalSubscriptionState, Never> { get }

    func retryConnection()
    func request(_ method: String, params: [String: Any], timeout: TimeInterval) async throws -> Any
    @discardableResult func onEvent(_ handler: @escaping (String, Any) -> Void) -> UUID
    func removeEventHandler(id: UUID)
    func registerSubscriptionHandler(id: String, handler: @escaping @MainActor (SubscriptionPush) -> Void)
    func unregisterSubscriptionHandler(id: String)
}

extension ConnectionManagerRouting {
    var capabilities: ConnectionCapabilities { .unknown }
    var capabilitiesPublisher: AnyPublisher<ConnectionCapabilities, Never> {
        Just(capabilities).eraseToAnyPublisher()
    }

    func disableScriptMonitors() {}

    var globalSubscriptionState: ConnectionManager.GlobalSubscriptionState { .subscribed }
    var globalSubscriptionPublisher: AnyPublisher<ConnectionManager.GlobalSubscriptionState, Never> {
        Just(globalSubscriptionState).eraseToAnyPublisher()
    }

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

    static let intentErrorDataCodeKey = "intentErrorDataCode"

    var intentErrorDataCode: String? {
        userInfo[Self.intentErrorDataCodeKey] as? String
    }

    var isEntityNotFound: Bool {
        domain == Self.webSocketErrorDomain
            && code == Self.jsonRPCInvalidParametersErrorCode
            && intentErrorDataCode == "not-found"
    }
}
