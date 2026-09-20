import Foundation

nonisolated private enum PendingMessageKind: Sendable {
    case binary
    case none
    case text
}

extension WebSocketConnection {
    nonisolated enum MessageAssemblyError: Error, Equatable, Sendable {
        case invalidTextEncoding
    }

    nonisolated enum FragmentKind: Sendable {
        case text
        case binary
        case continuation
    }

    /// Reassembles fragmented websocket messages: NWConnection.receiveMessage
    /// may deliver a message in chunks (isComplete false, then .cont frames),
    /// where URLSessionWebSocketTask.receive() always delivered whole messages.
    /// Pure and unit-testable; text is UTF-8-decoded only once the message is
    /// complete so multi-byte characters split across fragments stay intact.
    nonisolated struct MessageAssembler {
        private var pendingKind = PendingMessageKind.none
        private var buffer = Data()

        mutating func consume(
            kind: FragmentKind,
            data: Data,
            isComplete: Bool
        ) throws -> URLSessionWebSocketTask.Message? {
            switch kind {
            case .text:
                pendingKind = .text
                buffer = data
            case .binary:
                pendingKind = .binary
                buffer = data
            case .continuation:
                // A continuation with no message in progress is a protocol
                // violation; drop it rather than fabricate a message.
                guard pendingKind != .none else { return nil }
                buffer.append(data)
            }
            guard isComplete, pendingKind != .none else { return nil }
            defer {
                pendingKind = .none
                buffer = Data()
            }
            switch pendingKind {
            case .text:
                guard let text = String(bytes: buffer, encoding: .utf8) else {
                    throw MessageAssemblyError.invalidTextEncoding
                }
                return .string(text)
            case .binary:
                return .data(buffer)
            case .none:
                return nil
            }
        }
    }
}
