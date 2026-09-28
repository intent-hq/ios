import Foundation

/// The /tunnel wire format is independent of JSON-RPC (protocol §1.4).
nonisolated struct BrowserTunnelFrame: Equatable, Sendable {
    enum Opcode: UInt8, Sendable {
        case open = 0x01
        case openOK = 0x02
        case openError = 0x03
        case data = 0x04
        case eof = 0x05
        case close = 0x06
        case credit = 0x07
    }

    static let headerSize = 5
    static let maximumPayloadSize = 1_048_576
    static let maximumMessageSize = headerSize + maximumPayloadSize
    private static let bitsPerByte = 8
    private static let streamIDSize = 4
    private static let portSize = 2

    let opcode: Opcode
    let streamID: UInt32
    var payload = Data()

    init(opcode: Opcode, streamID: UInt32, payload: Data = Data()) {
        self.opcode = opcode
        self.streamID = streamID
        self.payload = payload
    }

    // Exhaustive validation follows the protocol opcode table.
    init(decoding data: Data) throws {
        guard (Self.headerSize...Self.maximumMessageSize).contains(data.count),
              let first = data.first, let opcode = Opcode(rawValue: first) else {
            throw BrowserTunnelError.invalidFrame
        }
        self.opcode = opcode
        streamID = data.dropFirst().prefix(Self.streamIDSize).reduce(UInt32(0)) { accumulated, byte in
            (accumulated << Self.bitsPerByte) | UInt32(byte)
        }
        payload = Data(data.dropFirst(Self.headerSize))
        switch opcode {
        case .open:
            guard payload.count == Self.portSize else { throw BrowserTunnelError.invalidFrame }
        case .credit:
            guard payload.count == Self.streamIDSize, payload.contains(where: { $0 != 0 }) else {
                throw BrowserTunnelError.invalidFrame
            }
        case .openOK, .eof, .close:
            guard payload.isEmpty else { throw BrowserTunnelError.invalidFrame }
        case .openError:
            guard String(data: payload, encoding: .utf8) != nil else { throw BrowserTunnelError.invalidFrame }
        case .data:
            break
        }
    }

    static func fromDaemon(_ message: URLSessionWebSocketTask.Message) throws -> Self {
        guard case .data(let data) = message else { throw BrowserTunnelError.invalidFrame }
        let frame = try Self(decoding: data)
        guard frame.opcode != .open, frame.opcode != .credit else { throw BrowserTunnelError.invalidFrame }
        return frame
    }

    var creditAmount: UInt32 {
        payload.reduce(UInt32(0)) { ($0 << Self.bitsPerByte) | UInt32($1) }
    }

    var encoded: Data {
        Data([opcode.rawValue]) + Self.bigEndian(streamID) + payload
    }

    static func bigEndian<Value: FixedWidthInteger>(_ value: Value) -> Data {
        var value = value.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    static func supportsCredit(protocolVersion: String?) -> Bool {
        guard let protocolVersion else { return false }
        let parts = protocolVersion.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ part in !part.isEmpty && part.allSatisfy { character in character.isASCII && character.isNumber } }),
              let major = Int(parts[0]), let minor = Int(parts[1]) else { return false }
        let creditMajor = 10
        let creditMinor = 4
        return major > creditMajor || (major == creditMajor && minor >= creditMinor)
    }
}

nonisolated enum BrowserTunnelError: LocalizedError, Equatable {
    case capacity
    case closed
    case invalidFrame
    case invalidURL
    case timedOut
    case unavailable

    var errorDescription: String? {
        switch self {
        case .capacity: "The browser has reached its connection limit. Try again after closing a page."
        case .closed: "The browser connection closed. Reopen the page to reconnect."
        case .invalidFrame: "The server sent an invalid browser tunnel message."
        case .invalidURL: "Enter an HTTP or HTTPS URL with a valid server port."
        case .timedOut: "The browser connection timed out."
        case .unavailable: "Connect to a backend before opening a workspace server."
        }
    }
}
