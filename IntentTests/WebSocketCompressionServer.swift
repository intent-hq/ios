import Foundation
@testable import Intent
import Network
import os

/// Loopback plain-WS server that speaks the upgrade and framing with the
/// app's own codecs (server role) and can accept permessage-deflate like
/// intentd does. It echoes every text/binary message, counts raw socket
/// bytes in each direction, and records the RSV1 bit of client frames.
nonisolated final class CompressionWebSocketServer: @unchecked Sendable {
    enum Mode: Sendable {
        /// Accept a permessage-deflate offer with default parameters.
        case acceptDeflate
        /// Never send `Sec-WebSocket-Extensions` (plain RFC 6455).
        case decline
        /// Answer with this raw extension header regardless of the offer.
        case respondWith(String)
        /// Decline, then send one RSV1 frame anyway.
        case compressedFrameWithoutNegotiation
        /// Accept, then send one compressed message inflating past `bytes`.
        case inflationBomb(bytes: Int)
        /// Read the upgrade request and never answer it.
        case neverUpgrade
    }

    private struct State {
        var requestHeaders: [String] = []
        var bytesRead = 0
        var bytesWritten = 0
        var clientFrameCompression: [Bool] = []
        var pongs: [Data] = []
        var closeReceived = false
        var framesAfterClose = 0
        var connections: [NWConnection] = []
    }

    private static let readChunkSize = 65_536

    private let listener: NWListener
    private let queue = DispatchQueue(label: "CompressionWebSocketServer")
    private let mode: Mode
    private let state = OSAllocatedUnfairLock(initialState: State())

    var port: Int { Int(listener.port?.rawValue ?? 0) }
    var bytesRead: Int { state.withLock { $0.bytesRead } }
    var bytesWritten: Int { state.withLock { $0.bytesWritten } }
    var requestHeaders: [String] { state.withLock { $0.requestHeaders } }
    var clientFrameCompression: [Bool] { state.withLock { $0.clientFrameCompression } }
    var pongs: [Data] { state.withLock { $0.pongs } }
    var closeReceived: Bool { state.withLock { $0.closeReceived } }
    var framesAfterClose: Int { state.withLock { $0.framesAfterClose } }

    private init(mode: Mode) throws {
        self.mode = mode
        listener = try NWListener.loopback()
    }

    static func start(mode: Mode) async throws -> CompressionWebSocketServer {
        let server = try CompressionWebSocketServer(mode: mode)
        try await server.listen()
        return server
    }

    func stop() {
        listener.cancel()
        for connection in state.withLock({ $0.connections }) { connection.cancel() }
    }

    /// Sends a ping to every connected client.
    func ping(_ payload: Data) {
        let frame = WebSocketFrameEncoder.encode(WebSocketFrame(opcode: .ping, payload: payload), maskingKey: nil)
        for connection in state.withLock({ $0.connections }) { write(frame, on: connection) }
    }

    private func listen() async throws {
        let ready = OSAllocatedUnfairLock<CheckedContinuation<Void, Error>?>(initialState: nil)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ready.withLock { $0 = continuation }
            listener.stateUpdateHandler = { listenerState in
                switch listenerState {
                case .ready: Self.take(ready)?.resume()
                case .failed(let error): Self.take(ready)?.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private static func take(_ slot: OSAllocatedUnfairLock<CheckedContinuation<Void, Error>?>) -> CheckedContinuation<Void, Error>? {
        slot.withLock { value in
            defer { value = nil }
            return value
        }
    }

    /// The server-side codec, confined to the server queue.
    private final class Codec: @unchecked Sendable {
        let deflate: PerMessageDeflate?

        init(_ deflate: PerMessageDeflate?) {
            self.deflate = deflate
        }
    }

    private func accept(_ connection: NWConnection) {
        state.withLock { $0.connections.append(connection) }
        connection.start(queue: queue)
        readHandshake(connection, buffer: Data())
    }

    private func receiveChunk(_ connection: NWConnection, _ handler: @escaping @Sendable (Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.readChunkSize) { [weak self] content, _, isComplete, error in
            guard let self, error == nil else { return }
            if let content, !content.isEmpty {
                state.withLock { $0.bytesRead += content.count }
                handler(content)
            } else if isComplete {
                connection.cancel()
            } else {
                handler(Data())
            }
        }
    }

    private func write(_ data: Data, on connection: NWConnection) {
        state.withLock { $0.bytesWritten += data.count }
        connection.send(content: data, completion: .idempotent)
    }

    private func readHandshake(_ connection: NWConnection, buffer: Data) {
        receiveChunk(connection) { [weak self] chunk in
            guard let self else { return }
            var buffer = buffer
            buffer.append(chunk)
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)),
                  let head = String(bytes: buffer[..<end.lowerBound], encoding: .utf8) else {
                readHandshake(connection, buffer: buffer)
                return
            }
            respond(to: head, on: connection, leftover: Data(buffer[end.upperBound...]))
        }
    }

    private func respond(to head: String, on connection: NWConnection, leftover: Data) {
        let headers = Array(head.components(separatedBy: "\r\n").dropFirst())
        state.withLock { $0.requestHeaders = headers }
        if case .neverUpgrade = mode { return }
        let value = { (name: String) in
            headers.first { $0.lowercased().hasPrefix(name.lowercased() + ":") }
                .map { String($0.drop { $0 != ":" }.dropFirst()).trimmingCharacters(in: .whitespaces) }
        }
        let offered = value("Sec-WebSocket-Extensions")?.hasPrefix("permessage-deflate") == true
        let extensionHeader: String?
        switch mode {
        case .acceptDeflate, .inflationBomb:
            extensionHeader = offered ? "permessage-deflate" : nil
        case .decline, .compressedFrameWithoutNegotiation, .neverUpgrade:
            extensionHeader = nil
        case .respondWith(let header):
            extensionHeader = header
        }
        var response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        response += "Sec-WebSocket-Accept: \(WebSocketHandshake.acceptValue(forKey: value("Sec-WebSocket-Key") ?? ""))\r\n"
        if let extensionHeader { response += "Sec-WebSocket-Extensions: \(extensionHeader)\r\n" }
        write(Data((response + "\r\n").utf8), on: connection)
        // Server-side codec: the server deflates with the client's
        // inbound parameters and inflates with its own.
        let codec = Codec(extensionHeader == "permessage-deflate" ? try? PerMessageDeflate(parameters: PerMessageDeflateParameters()) : nil)
        afterUpgrade(connection, deflate: codec.deflate)
        var decoder = WebSocketFrameDecoder(
            role: .server,
            maximumFrameSize: WebSocketConnection.maximumMessageSize,
            allowsCompressedFrames: codec.deflate != nil
        )
        decoder.append(leftover)
        pump(connection, decoder: decoder, codec: codec, message: nil)
    }

    private func afterUpgrade(_ connection: NWConnection, deflate: PerMessageDeflate?) {
        switch mode {
        case .compressedFrameWithoutNegotiation:
            // A valid compressed "Hello" from a fresh context, sent although
            // compression was not negotiated.
            guard let payload = try? PerMessageDeflate(parameters: PerMessageDeflateParameters()).compress(Data("Hello".utf8)) else { return }
            let frame = WebSocketFrame(opcode: .text, payload: payload, isCompressed: true)
            write(WebSocketFrameEncoder.encode(frame, maskingKey: nil), on: connection)
        case .inflationBomb(let bytes):
            guard let payload = deflate?.compress(Data(count: bytes)) else { return }
            let frame = WebSocketFrame(opcode: .binary, payload: payload, isCompressed: true)
            write(WebSocketFrameEncoder.encode(frame, maskingKey: nil), on: connection)
        case .acceptDeflate, .decline, .respondWith, .neverUpgrade:
            break
        }
    }

    private struct PartialMessage: Sendable {
        var opcode: WebSocketOpcode
        var compressed: Bool
        var payload: Data
    }

    private func pump(_ connection: NWConnection, decoder: WebSocketFrameDecoder, codec: Codec, message: PartialMessage?) {
        var decoder = decoder
        var message = message
        do {
            while let frame = try decoder.nextFrame() {
                switch frame.opcode {
                case .ping:
                    write(WebSocketFrameEncoder.encode(WebSocketFrame(opcode: .pong, payload: frame.payload), maskingKey: nil), on: connection)
                case .pong:
                    state.withLock { $0.pongs.append(frame.payload) }
                case .close:
                    // Keep reading so data frames sent after the close frame
                    // (an RFC 6455 §5.5.1 violation) are observable.
                    write(WebSocketFrameEncoder.encode(WebSocketFrame(opcode: .close, payload: frame.payload), maskingKey: nil), on: connection)
                    state.withLock { $0.closeReceived = true }
                case .text, .binary:
                    let afterClose = state.withLock { state in
                        if state.closeReceived { state.framesAfterClose += 1 }
                        return state.closeReceived
                    }
                    if afterClose { continue }
                    state.withLock { $0.clientFrameCompression.append(frame.isCompressed) }
                    message = PartialMessage(opcode: frame.opcode, compressed: frame.isCompressed, payload: frame.payload)
                case .continuation:
                    message?.payload.append(frame.payload)
                }
                if frame.isFinal, let complete = message, !frame.opcode.isControl {
                    message = nil
                    try echo(complete, on: connection, deflate: codec.deflate)
                }
            }
        } catch {
            connection.cancel()
            return
        }
        receiveChunk(connection) { [weak self, decoder, message] chunk in
            var next = decoder
            next.append(chunk)
            self?.pump(connection, decoder: next, codec: codec, message: message)
        }
    }

    private func echo(_ message: PartialMessage, on connection: NWConnection, deflate: PerMessageDeflate?) throws {
        var payload = message.payload
        if message.compressed, let deflate {
            payload = try deflate.decompress(payload, maximumSize: WebSocketConnection.maximumMessageSize)
        }
        let compressed = deflate?.compressIfWorthwhile(payload)
        let frame = WebSocketFrame(opcode: message.opcode, payload: compressed ?? payload, isCompressed: compressed != nil)
        write(WebSocketFrameEncoder.encode(frame, maskingKey: nil), on: connection)
    }
}
