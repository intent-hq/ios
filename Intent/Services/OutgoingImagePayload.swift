import Foundation

enum OutgoingImagePayload {
    case attachments([[String: Any]])
    case inline([[String: Any]])
    case none

    enum RequestError: LocalizedError {
        case tooLarge

        var errorDescription: String? {
            "The message and attached images are too large to send together. Remove an image or shorten the message and try again."
        }
    }

    func apply(to params: inout [String: Any]) {
        switch self {
        case let .attachments(blocks), let .inline(blocks): params["imageBlocks"] = blocks
        case .none: break
        }
    }

    /// Inline images share the host's 40 MiB frame with text, metadata and JSON
    /// escaping. Match ConnectionManager's serializer; Int.min bounds RPC id size.
    func validateRequest(method: String, params: [String: Any]) throws {
        guard case .inline = self else { return }
        let envelope: [String: Any] = ["jsonrpc": "2.0", "id": Int.min, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        guard data.count <= WebSocketConnection.maximumMessageSize else { throw RequestError.tooLarge }
    }
}
