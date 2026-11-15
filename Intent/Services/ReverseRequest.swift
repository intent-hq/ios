import Foundation

/// Serves one daemon-issued reverse RPC. Returns the JSON result, or throws a
/// ``ReverseRequestError`` that becomes the JSON-RPC error reply.
typealias ReverseRequestHandler = @MainActor (_ method: String, _ params: [String: Any]) async throws -> Any

nonisolated struct ReverseRequestError: Error, Equatable {
    static let methodNotFoundCode = -32_601
    static let invalidParamsCode = -32_602
    static let internalErrorCode = -32_603

    let code: Int
    let message: String

    static func methodNotFound(_ method: String) -> Self {
        Self(code: methodNotFoundCode, message: "Method not found: \(method)")
    }

    static func invalidParams(_ message: String) -> Self {
        Self(code: invalidParamsCode, message: message)
    }

    static func internalError(_ message: String) -> Self {
        Self(code: internalErrorCode, message: message)
    }
}

extension ConnectionManager {
    func setReverseRequestHandler(_ handler: ReverseRequestHandler?) {
        reverseRequestHandler = handler
    }

    /// Answers on the socket the request arrived on; a reply for a replaced socket is dropped
    /// because the daemon already failed the request when that connection closed.
    func serveReverseRequest(id: String, method: String, params: Any) {
        let currentSocket = socket
        let handler = reverseRequestHandler
        Task { @MainActor [weak self] in
            let reply: [String: Any]
            do {
                guard let handler else { throw ReverseRequestError.methodNotFound(method) }
                let result = try await handler(method, params as? [String: Any] ?? [:])
                reply = ["jsonrpc": "2.0", "id": id, "result": result]
            } catch let error as ReverseRequestError {
                reply = ["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]]
            } catch {
                reply = [
                    "jsonrpc": "2.0", "id": id,
                    "error": ["code": ReverseRequestError.internalErrorCode, "message": error.localizedDescription]
                ]
            }
            guard let self, let currentSocket, socket === currentSocket,
                  JSONSerialization.isValidJSONObject(reply),
                  let data = try? JSONSerialization.data(withJSONObject: reply),
                  let text = String(data: data, encoding: .utf8) else { return }
            do { try await currentSocket.send(text) } catch {
                AppLog.connection.debug("[ConnectionManager] Reverse reply id=\(id) failed: \(error.localizedDescription)")
            }
        }
    }
}
