import Foundation
import zlib

/// Parameters agreed for RFC 7692 permessage-deflate. Defaults are the
/// extension's defaults: 15-bit windows with context takeover both ways.
nonisolated struct PerMessageDeflateParameters: Equatable, Sendable {
    static let extensionName = "permessage-deflate"
    /// The client offer: the same one Chromium sends, which intentd accepts.
    static let offer = "permessage-deflate; client_max_window_bits"
    static let minimumWindowBits = 8
    static let maximumWindowBits = 15

    var serverNoContextTakeover = false
    var clientNoContextTakeover = false
    var serverMaxWindowBits = maximumWindowBits
    var clientMaxWindowBits = maximumWindowBits

    /// Validates the parameters of a server's permessage-deflate response
    /// (RFC 7692 §7.1) against the client offer `offer`. Unknown, repeated,
    /// or malformed parameters decline the response.
    init(responseParameters: [(name: String, value: String?)]) throws {
        var seen = Set<String>()
        for parameter in responseParameters {
            let name = parameter.name.lowercased()
            guard seen.insert(name).inserted else { throw PerMessageDeflateError.invalidParameters }
            switch name {
            case "server_no_context_takeover":
                guard parameter.value == nil else { throw PerMessageDeflateError.invalidParameters }
                serverNoContextTakeover = true
            case "client_no_context_takeover":
                guard parameter.value == nil else { throw PerMessageDeflateError.invalidParameters }
                clientNoContextTakeover = true
            case "server_max_window_bits":
                serverMaxWindowBits = try Self.windowBits(parameter.value)
            case "client_max_window_bits":
                // Allowed only because the offer included client_max_window_bits;
                // a response must carry a value (§7.1.2.2).
                clientMaxWindowBits = try Self.windowBits(parameter.value)
            default:
                throw PerMessageDeflateError.invalidParameters
            }
        }
    }

    init() {}

    private static func windowBits(_ value: String?) throws -> Int {
        guard let value, value.first != "0", let bits = Int(value),
              (minimumWindowBits...maximumWindowBits).contains(bits) else {
            throw PerMessageDeflateError.invalidParameters
        }
        return bits
    }
}

nonisolated enum PerMessageDeflateError: Error, Equatable, Sendable {
    case initializationFailed
    case invalidParameters
}

/// zlib-backed RFC 7692 codec for one connection. Compression uses raw
/// deflate with `Z_SYNC_FLUSH` and trims the trailing empty stored block
/// (0x00 0x00 0xFF 0xFF); inflation appends it back. Context is kept across
/// messages unless the peer negotiated `*_no_context_takeover`.
///
/// Not thread-safe: the owning `WebSocketConnection` actor serializes use.
nonisolated final class PerMessageDeflate {
    /// Outbound messages smaller than this are sent uncompressed (RSV1
    /// clear), matching the Node `ws` default the desktop client uses.
    static let defaultCompressionThreshold = 1024
    private static let syncFlushTail: [UInt8] = [0, 0, .max, .max]
    private static let chunkSize = 16_384
    private static let memoryLevel: Int32 = 8
    /// zlib cannot produce raw deflate with an 8-bit window (it silently
    /// widens to 9), so a peer limiting the client to 8 bits gets
    /// uncompressed messages instead (RSV1 is per message and optional).
    private static let smallestDeflatableWindow = 9

    let parameters: PerMessageDeflateParameters
    let compressionThreshold: Int
    private let deflater: UnsafeMutablePointer<z_stream>?
    private let inflater: UnsafeMutablePointer<z_stream>

    init(
        parameters: PerMessageDeflateParameters,
        compressionThreshold: Int = defaultCompressionThreshold
    ) throws {
        self.parameters = parameters
        self.compressionThreshold = compressionThreshold
        let inflater = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        inflater.initialize(to: z_stream())
        // A 15-bit inflate window decodes streams from any smaller window.
        guard inflateInit2_(
            inflater,
            -Int32(PerMessageDeflateParameters.maximumWindowBits),
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else {
            inflater.deallocate()
            throw PerMessageDeflateError.initializationFailed
        }
        self.inflater = inflater
        guard parameters.clientMaxWindowBits >= Self.smallestDeflatableWindow else {
            deflater = nil
            return
        }
        let deflater = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        deflater.initialize(to: z_stream())
        guard deflateInit2_(
            deflater,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            -Int32(parameters.clientMaxWindowBits),
            Self.memoryLevel,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else {
            deflater.deallocate()
            inflateEnd(inflater)
            inflater.deallocate()
            throw PerMessageDeflateError.initializationFailed
        }
        self.deflater = deflater
    }

    deinit {
        if let deflater {
            deflateEnd(deflater)
            deflater.deallocate()
        }
        inflateEnd(inflater)
        inflater.deallocate()
    }

    /// The compressed payload to send with RSV1 set, or nil when the message
    /// should go out uncompressed (below the threshold, or deflate disabled).
    func compressIfWorthwhile(_ payload: Data) -> Data? {
        guard deflater != nil, payload.count >= compressionThreshold else { return nil }
        return compress(payload)
    }

    /// Deflates one whole message payload (RFC 7692 §7.2.1).
    func compress(_ payload: Data) -> Data? {
        guard let deflater else { return nil }
        var output = Data()
        let succeeded = payload.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Bool in
            deflater.pointee.next_in = input.bindMemory(to: Bytef.self).baseAddress.map { UnsafeMutablePointer(mutating: $0) }
            deflater.pointee.avail_in = uInt(input.count)
            var exceeded = false
            return Self.drain(deflater, into: &output, limit: nil, exceeded: &exceeded) { deflate($0, Z_SYNC_FLUSH) }
        }
        deflater.pointee.next_in = nil
        guard succeeded else { return nil }
        if output.suffix(Self.syncFlushTail.count).elementsEqual(Self.syncFlushTail) {
            output.removeLast(Self.syncFlushTail.count)
        }
        if parameters.clientNoContextTakeover { deflateReset(deflater) }
        return output
    }

    /// Inflates one whole compressed message payload. Fails with
    /// `.messageTooLarge` as soon as the output would exceed `maximumSize`,
    /// so a small compressed frame cannot expand past the endpoint cap.
    func decompress(_ payload: Data, maximumSize: Int) throws -> Data {
        var input = payload
        input.append(contentsOf: Self.syncFlushTail)
        var output = Data()
        var exceeded = false
        let succeeded = input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            inflater.pointee.next_in = raw.bindMemory(to: Bytef.self).baseAddress.map { UnsafeMutablePointer(mutating: $0) }
            inflater.pointee.avail_in = uInt(raw.count)
            return Self.drain(inflater, into: &output, limit: maximumSize, exceeded: &exceeded) { stream in
                inflate(stream, Z_SYNC_FLUSH)
            }
        }
        inflater.pointee.next_in = nil
        if exceeded {
            inflateReset(inflater)
            throw WebSocketProtocolViolation.messageTooLarge
        }
        guard succeeded else {
            inflateReset(inflater)
            throw WebSocketProtocolViolation.invalidCompressedData
        }
        if parameters.serverNoContextTakeover { inflateReset(inflater) }
        return output
    }

    /// Runs `step` until all input is consumed and zlib stops filling the
    /// output chunk. Returns false on a zlib error or when `limit` is hit.
    private static func drain(
        _ stream: UnsafeMutablePointer<z_stream>,
        into output: inout Data,
        limit: Int?,
        exceeded: inout Bool,
        step: (UnsafeMutablePointer<z_stream>) -> Int32
    ) -> Bool {
        var chunk = [Bytef](repeating: 0, count: chunkSize)
        while true {
            let (status, produced) = chunk.withUnsafeMutableBufferPointer { buffer -> (Int32, Int) in
                stream.pointee.next_out = buffer.baseAddress
                stream.pointee.avail_out = uInt(buffer.count)
                let status = step(stream)
                return (status, buffer.count - Int(stream.pointee.avail_out))
            }
            stream.pointee.next_out = nil
            if let limit, output.count + produced > limit {
                exceeded = true
                return false
            }
            output.append(contentsOf: chunk[0..<produced])
            switch status {
            case Z_OK:
                if stream.pointee.avail_out != 0, stream.pointee.avail_in == 0 { return true }
            case Z_BUF_ERROR:
                // No progress possible: all input consumed and output flushed.
                return stream.pointee.avail_in == 0
            case Z_STREAM_END:
                // A final block (BFINAL) ends the stream (§7.2.3.4); anything
                // left is the appended sync-flush tail. The next message
                // starts a fresh stream, so reset to accept it.
                return inflateReset(stream) == Z_OK
            default:
                return false
            }
        }
    }
}
