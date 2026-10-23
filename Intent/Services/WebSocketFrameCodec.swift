import Foundation

/// RFC 6455 §5.2 opcodes. Values outside this set fail the connection.
nonisolated enum WebSocketOpcode: UInt8, Sendable {
    case binary = 0x2
    case close = 0x8
    case continuation = 0x0
    case ping = 0x9
    case pong = 0xA
    case text = 0x1

    /// Control opcodes have the high bit of the opcode nibble set (§5.5).
    var isControl: Bool { rawValue & WebSocketFrameLayout.controlOpcodeBit != 0 }
}

/// One RFC 6455 frame. `isCompressed` is the RSV1 bit, which RFC 7692 assigns
/// to permessage-deflate: set on the first frame of a compressed message.
nonisolated struct WebSocketFrame: Equatable, Sendable {
    var isFinal: Bool
    var isCompressed: Bool
    var opcode: WebSocketOpcode
    var payload: Data

    init(opcode: WebSocketOpcode, payload: Data = Data(), isFinal: Bool = true, isCompressed: Bool = false) {
        self.isFinal = isFinal
        self.isCompressed = isCompressed
        self.opcode = opcode
        self.payload = payload
    }
}

/// A peer behaviour that RFC 6455 or RFC 7692 requires the endpoint to fail
/// the connection for. `closeCode` is the status code sent in the close frame.
nonisolated enum WebSocketProtocolViolation: Error, Equatable, Sendable {
    case controlFrameTooLong
    case fragmentedControlFrame
    case frameTooLarge
    case invalidCloseFrame
    case invalidCompressedData
    case invalidMasking
    case invalidTextEncoding
    case messageTooLarge
    case reservedBitsSet
    case unexpectedContinuation
    case unexpectedDataFrame
    case unknownOpcode

    /// RFC 6455 §7.4.1 status code for this violation.
    var closeCode: UInt16 {
        switch self {
        case .frameTooLarge, .messageTooLarge:
            WebSocketCloseCode.messageTooBig
        case .invalidCompressedData, .invalidTextEncoding:
            WebSocketCloseCode.invalidFramePayloadData
        case .controlFrameTooLong, .fragmentedControlFrame, .invalidCloseFrame, .invalidMasking, .reservedBitsSet,
             .unexpectedContinuation, .unexpectedDataFrame, .unknownOpcode:
            WebSocketCloseCode.protocolError
        }
    }
}

/// RFC 6455 §7.4.1 status codes the client sends or interprets.
nonisolated enum WebSocketCloseCode {
    static let normalClosure: UInt16 = 1000
    static let goingAway: UInt16 = 1001
    static let protocolError: UInt16 = 1002
    static let missingStatus: UInt16 = 1005
    static let abnormalClosure: UInt16 = 1006
    static let invalidFramePayloadData: UInt16 = 1007
    static let messageTooBig: UInt16 = 1009
    static let tlsHandshake: UInt16 = 1015
    static let maximumApplication: UInt16 = 4999
}

/// Bit layout of the RFC 6455 §5.2 base framing protocol.
nonisolated enum WebSocketFrameLayout {
    static let finBit: UInt8 = 0x80
    static let rsv1Bit: UInt8 = 0x40
    static let rsv2And3Bits: UInt8 = 0x30
    static let opcodeMask: UInt8 = 0x0F
    static let controlOpcodeBit: UInt8 = 0x08
    static let maskBit: UInt8 = 0x80
    static let lengthMask: UInt8 = 0x7F
    static let maximumInlineLength = 125
    static let sixteenBitLengthMarker: UInt8 = 126
    static let sixtyFourBitLengthMarker: UInt8 = 127
    static let baseHeaderSize = 2
    static let sixteenBitLengthSize = 2
    static let sixtyFourBitLengthSize = 8
    static let maskingKeySize = 4
    static let bitsPerByte = 8
    static let maximumControlPayload = 125
}

/// The 4-byte client masking key (§5.3).
nonisolated struct WebSocketMaskingKey: Equatable, Sendable {
    let bytes: [UInt8]

    init(_ first: UInt8, _ second: UInt8, _ third: UInt8, _ fourth: UInt8) {
        bytes = [first, second, third, fourth]
    }

    /// Callers pass exactly `maskingKeySize` bytes read from a frame header.
    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    static func random() -> Self {
        var generator = SystemRandomNumberGenerator()
        return Self(
            .random(in: .min ... .max, using: &generator),
            .random(in: .min ... .max, using: &generator),
            .random(in: .min ... .max, using: &generator),
            .random(in: .min ... .max, using: &generator)
        )
    }

    /// XORs `buffer` with the repeating key. Masking and unmasking are the
    /// same operation.
    func apply(to buffer: UnsafeMutableRawBufferPointer) {
        for index in buffer.indices {
            buffer[index] ^= bytes[index % WebSocketFrameLayout.maskingKeySize]
        }
    }
}

/// Encodes frames for the wire. Client frames are always masked (§5.3);
/// passing a nil key produces an unmasked server frame, used by test servers.
nonisolated enum WebSocketFrameEncoder {
    static func encode(_ frame: WebSocketFrame, maskingKey: WebSocketMaskingKey?) -> Data {
        typealias Layout = WebSocketFrameLayout
        var first = frame.opcode.rawValue
        if frame.isFinal { first |= Layout.finBit }
        if frame.isCompressed { first |= Layout.rsv1Bit }
        let maskFlag: UInt8 = maskingKey == nil ? 0 : Layout.maskBit
        let length = frame.payload.count
        var output = Data()
        output.reserveCapacity(
            Layout.baseHeaderSize + Layout.sixtyFourBitLengthSize + Layout.maskingKeySize + length
        )
        output.append(first)
        if length <= Layout.maximumInlineLength {
            output.append(maskFlag | UInt8(length))
        } else if length <= Int(UInt16.max) {
            output.append(maskFlag | Layout.sixteenBitLengthMarker)
            appendBigEndian(UInt64(length), byteCount: Layout.sixteenBitLengthSize, to: &output)
        } else {
            output.append(maskFlag | Layout.sixtyFourBitLengthMarker)
            appendBigEndian(UInt64(length), byteCount: Layout.sixtyFourBitLengthSize, to: &output)
        }
        guard let maskingKey else {
            output.append(frame.payload)
            return output
        }
        output.append(contentsOf: maskingKey.bytes)
        let payloadStart = output.count
        output.append(frame.payload)
        output.withUnsafeMutableBytes { raw in
            maskingKey.apply(to: UnsafeMutableRawBufferPointer(rebasing: raw[payloadStart...]))
        }
        return output
    }

    private static func appendBigEndian(_ value: UInt64, byteCount: Int, to output: inout Data) {
        for shift in stride(from: (byteCount - 1) * WebSocketFrameLayout.bitsPerByte, through: 0, by: -WebSocketFrameLayout.bitsPerByte) {
            output.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }
}

/// Incremental frame decoder: append bytes as they arrive from the socket and
/// pull complete frames. Header-level checks (reserved bits, masking, control
/// frame rules, and the frame size cap) run as soon as the header is buffered,
/// so an oversized frame fails before any of its payload is buffered.
nonisolated struct WebSocketFrameDecoder {
    /// Which side of the connection decodes. Server frames must be unmasked;
    /// client frames must be masked (§5.1).
    enum Role: Sendable {
        case client
        case server
    }

    private static let compactionThreshold = 65_536

    let role: Role
    let maximumFrameSize: Int
    /// Whether RSV1 is meaningful (permessage-deflate negotiated).
    var allowsCompressedFrames: Bool
    private var buffer = Data()
    private var offset = 0

    init(role: Role, maximumFrameSize: Int, allowsCompressedFrames: Bool = false) {
        self.role = role
        self.maximumFrameSize = maximumFrameSize
        self.allowsCompressedFrames = allowsCompressedFrames
    }

    var bufferedByteCount: Int { buffer.count - offset }

    mutating func append(_ bytes: Data) {
        if offset > 0, offset >= Self.compactionThreshold || offset == buffer.count {
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + offset))
            offset = 0
        }
        buffer.append(bytes)
    }

    /// Returns the next complete frame, nil when more bytes are needed, or
    /// throws when the buffered header violates the protocol.
    mutating func nextFrame() throws -> WebSocketFrame? {
        guard let header = try parseHeader() else { return nil }
        let payloadStart = buffer.startIndex + offset + header.size
        guard buffer.endIndex - payloadStart >= header.payloadLength else { return nil }
        var payload = Data(buffer[payloadStart..<(payloadStart + header.payloadLength)])
        if let key = header.maskingKey {
            payload.withUnsafeMutableBytes { key.apply(to: $0) }
        }
        offset += header.size + header.payloadLength
        return WebSocketFrame(
            opcode: header.opcode,
            payload: payload,
            isFinal: header.isFinal,
            isCompressed: header.isCompressed
        )
    }

    private struct Header {
        let isFinal: Bool
        let isCompressed: Bool
        let opcode: WebSocketOpcode
        let payloadLength: Int
        let maskingKey: WebSocketMaskingKey?
        let size: Int
    }

    private func byte(at position: Int) -> UInt8 {
        buffer[buffer.startIndex + offset + position]
    }

    private func parseHeader() throws -> Header? {
        typealias Layout = WebSocketFrameLayout
        guard bufferedByteCount >= Layout.baseHeaderSize else { return nil }
        let first = byte(at: 0)
        let second = byte(at: 1)
        let opcode = try validatedOpcode(first: first, second: second)
        guard let length = readPayloadLength(inlineLength: second & Layout.lengthMask) else { return nil }
        guard length.value <= UInt64(maximumFrameSize) else { throw WebSocketProtocolViolation.frameTooLarge }
        var size = length.headerSize
        var maskingKey: WebSocketMaskingKey?
        if second & Layout.maskBit != 0 {
            guard bufferedByteCount >= size + Layout.maskingKeySize else { return nil }
            maskingKey = WebSocketMaskingKey(bytes: (size..<(size + Layout.maskingKeySize)).map(byte(at:)))
            size += Layout.maskingKeySize
        }
        return Header(
            isFinal: first & Layout.finBit != 0,
            isCompressed: first & Layout.rsv1Bit != 0,
            opcode: opcode,
            payloadLength: Int(length.value),
            maskingKey: maskingKey,
            size: size
        )
    }

    /// Checks the first two header bytes against §5.2 and §5.5 rules.
    private func validatedOpcode(first: UInt8, second: UInt8) throws -> WebSocketOpcode {
        typealias Layout = WebSocketFrameLayout
        guard first & Layout.rsv2And3Bits == 0 else { throw WebSocketProtocolViolation.reservedBitsSet }
        guard let opcode = WebSocketOpcode(rawValue: first & Layout.opcodeMask) else {
            throw WebSocketProtocolViolation.unknownOpcode
        }
        if first & Layout.rsv1Bit != 0, !allowsCompressedFrames || opcode.isControl {
            throw WebSocketProtocolViolation.reservedBitsSet
        }
        guard (second & Layout.maskBit != 0) == (role == .server) else { throw WebSocketProtocolViolation.invalidMasking }
        if opcode.isControl {
            guard first & Layout.finBit != 0 else { throw WebSocketProtocolViolation.fragmentedControlFrame }
            guard Int(second & Layout.lengthMask) <= Layout.maximumControlPayload else {
                throw WebSocketProtocolViolation.controlFrameTooLong
            }
        }
        return opcode
    }

    /// The payload length and the header size up to the masking key, or nil
    /// while the extended length bytes are not yet buffered.
    private func readPayloadLength(inlineLength: UInt8) -> (value: UInt64, headerSize: Int)? {
        typealias Layout = WebSocketFrameLayout
        let extendedSize: Int
        switch inlineLength {
        case Layout.sixteenBitLengthMarker: extendedSize = Layout.sixteenBitLengthSize
        case Layout.sixtyFourBitLengthMarker: extendedSize = Layout.sixtyFourBitLengthSize
        default: return (UInt64(inlineLength), Layout.baseHeaderSize)
        }
        guard let value = readBigEndian(at: Layout.baseHeaderSize, byteCount: extendedSize) else { return nil }
        return (value, Layout.baseHeaderSize + extendedSize)
    }

    private func readBigEndian(at position: Int, byteCount: Int) -> UInt64? {
        guard bufferedByteCount >= position + byteCount else { return nil }
        return (0..<byteCount).reduce(UInt64(0)) { value, index in
            (value << UInt64(WebSocketFrameLayout.bitsPerByte)) | UInt64(byte(at: position + index))
        }
    }
}
