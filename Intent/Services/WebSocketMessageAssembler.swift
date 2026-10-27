import Foundation

nonisolated private enum PendingMessageKind: Sendable {
    case binary
    case none
    case text
}

extension WebSocketConnection {
    nonisolated enum MessageAssemblyError: Error, Equatable, Sendable {
        case invalidTextEncoding
        case protocolViolation(WebSocketProtocolViolation)
    }

    nonisolated enum FragmentKind: Sendable {
        case text
        case binary
        case continuation
    }

    /// Reassembles fragmented websocket messages into whole messages. Pure and
    /// unit-testable; text is UTF-8-decoded only once the message is complete
    /// (and inflated) so multi-byte characters split across fragments stay
    /// intact. A message whose first frame had RSV1 set is inflated with the
    /// negotiated permessage-deflate context after reassembly; both the
    /// buffered and the inflated size are capped at `maximumMessageSize`.
    nonisolated struct MessageAssembler {
        var diagnostics: DiagnosticStore
        let maximumMessageSize: Int
        private let deflate: PerMessageDeflate?
        private var pendingKind = PendingMessageKind.none
        private var pendingCompressed = false
        private var buffer = Data()

        init(diagnostics: DiagnosticStore = .shared, maximumMessageSize: Int = .max, deflate: PerMessageDeflate? = nil) {
            self.diagnostics = diagnostics
            self.maximumMessageSize = maximumMessageSize
            self.deflate = deflate
        }

        /// Whether a fragmented message is waiting for its final frame.
        var hasPendingMessage: Bool { pendingKind != .none }

        mutating func consume(
            kind: FragmentKind,
            data: Data,
            isComplete: Bool,
            isCompressed: Bool = false
        ) throws -> URLSessionWebSocketTask.Message? {
            switch kind {
            case .text:
                pendingKind = .text
                pendingCompressed = isCompressed
                buffer = data
            case .binary:
                pendingKind = .binary
                pendingCompressed = isCompressed
                buffer = data
            case .continuation:
                // A continuation with no message in progress is a protocol
                // violation; drop it rather than fabricate a message.
                guard pendingKind != .none else {
                    recordFailure()
                    return nil
                }
                buffer.append(data)
            }
            guard buffer.count <= maximumMessageSize else {
                reset()
                throw MessageAssemblyError.protocolViolation(.messageTooLarge)
            }
            guard isComplete, pendingKind != .none else { return nil }
            defer { reset() }
            let payload = try inflatedPayload()
            switch pendingKind {
            case .text:
                guard let text = String(bytes: payload, encoding: .utf8) else {
                    recordFailure()
                    throw MessageAssemblyError.invalidTextEncoding
                }
                return .string(text)
            case .binary:
                return .data(payload)
            case .none:
                return nil
            }
        }

        private func inflatedPayload() throws -> Data {
            guard pendingCompressed else { return buffer }
            guard let deflate else { throw MessageAssemblyError.protocolViolation(.reservedBitsSet) }
            do {
                return try deflate.decompress(buffer, maximumSize: maximumMessageSize)
            } catch let violation as WebSocketProtocolViolation {
                recordFailure()
                throw MessageAssemblyError.protocolViolation(violation)
            }
        }

        private mutating func reset() {
            pendingKind = .none
            pendingCompressed = false
            buffer = Data()
        }

        private func recordFailure() {
            diagnostics.record(DiagnosticEvent(
                kind: .operationFailed,
                operation: .protocolMessageAssembly,
                site: .webSocket,
                stage: .decode,
                outcome: .failed,
                failure: DiagnosticFailure(origin: .transport, classification: .malformedResponse)
            ))
        }
    }

    /// What the receive path should do next with the decoded stream.
    nonisolated enum InboundEvent: Sendable {
        case close(code: Int, reason: String)
        case message(URLSessionWebSocketTask.Message)
        case ping(Data)
        case pong(Data)
    }

    /// Turns raw socket bytes into messages and control events: frame
    /// decoding, RFC 6455 fragmentation rules, and permessage-deflate. Pure;
    /// the connection feeds bytes and acts on events (pong replies, close).
    nonisolated struct InboundStream {
        private var decoder: WebSocketFrameDecoder
        private var assembler: MessageAssembler

        init(maximumMessageSize: Int, deflate: PerMessageDeflate?, diagnostics: DiagnosticStore = .shared) {
            decoder = WebSocketFrameDecoder(
                role: .client,
                maximumFrameSize: maximumMessageSize,
                allowsCompressedFrames: deflate != nil
            )
            assembler = MessageAssembler(diagnostics: diagnostics, maximumMessageSize: maximumMessageSize, deflate: deflate)
        }

        mutating func append(_ bytes: Data) {
            decoder.append(bytes)
        }

        /// The next event, nil when more bytes are needed. Throws a
        /// `MessageAssemblyError` when the peer must be failed.
        mutating func nextEvent() throws -> InboundEvent? {
            while true {
                let frame: WebSocketFrame
                do {
                    guard let decoded = try decoder.nextFrame() else { return nil }
                    frame = decoded
                } catch let violation as WebSocketProtocolViolation {
                    throw MessageAssemblyError.protocolViolation(violation)
                }
                if let event = try event(for: frame) { return event }
            }
        }

        private mutating func event(for frame: WebSocketFrame) throws -> InboundEvent? {
            switch frame.opcode {
            case .ping:
                return .ping(frame.payload)
            case .pong:
                return .pong(frame.payload)
            case .close:
                return try Self.closeEvent(frame.payload)
            case .text, .binary:
                guard !assembler.hasPendingMessage else {
                    throw MessageAssemblyError.protocolViolation(.unexpectedDataFrame)
                }
                let message = try assembler.consume(
                    kind: frame.opcode == .text ? .text : .binary,
                    data: frame.payload,
                    isComplete: frame.isFinal,
                    isCompressed: frame.isCompressed
                )
                return message.map(InboundEvent.message)
            case .continuation:
                // RSV1 marks only a message's first frame (RFC 7692 §6.1).
                guard assembler.hasPendingMessage, !frame.isCompressed else {
                    throw MessageAssemblyError.protocolViolation(
                        frame.isCompressed ? .reservedBitsSet : .unexpectedContinuation
                    )
                }
                return try assembler.consume(kind: .continuation, data: frame.payload, isComplete: frame.isFinal)
                    .map(InboundEvent.message)
            }
        }

        private static let closeCodeSize = 2

        private static func closeEvent(_ payload: Data) throws -> InboundEvent {
            guard !payload.isEmpty else {
                return .close(code: Int(WebSocketCloseCode.missingStatus), reason: "Connection closed")
            }
            guard payload.count >= closeCodeSize else {
                throw MessageAssemblyError.protocolViolation(.invalidCloseFrame)
            }
            let start = payload.startIndex
            let code = UInt16(payload[start]) << WebSocketFrameLayout.bitsPerByte | UInt16(payload[start + 1])
            // Network.framework used to enforce these; the peer must not send
            // reserved or out-of-range codes (RFC 6455 §7.4.1, §7.4.2).
            guard WebSocketCloseCode.isSendable(code) else {
                throw MessageAssemblyError.protocolViolation(.invalidCloseFrame)
            }
            guard let reason = String(bytes: payload.dropFirst(closeCodeSize), encoding: .utf8) else {
                throw MessageAssemblyError.invalidTextEncoding
            }
            return .close(code: Int(code), reason: reason.isEmpty ? "Connection closed" : reason)
        }
    }
}
