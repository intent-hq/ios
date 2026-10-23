import Foundation
@testable import Intent
import Testing

/// RFC 6455 §5 framing: vectors from §5.7 plus boundary and violation cases.
struct WebSocketFrameCodecTests {
    private static let helloBytes: [UInt8] = [0x48, 0x65, 0x6C, 0x6C, 0x6F]
    private static let rfcMaskingKey = WebSocketMaskingKey(0x37, 0xFA, 0x21, 0x3D)
    private static let largeCap = 1 << 20

    private func decodeAll(_ bytes: [UInt8], role: WebSocketFrameDecoder.Role = .client, compressed: Bool = false) throws -> [WebSocketFrame] {
        var decoder = WebSocketFrameDecoder(role: role, maximumFrameSize: Self.largeCap, allowsCompressedFrames: compressed)
        decoder.append(Data(bytes))
        var frames: [WebSocketFrame] = []
        while let frame = try decoder.nextFrame() { frames.append(frame) }
        #expect(decoder.bufferedByteCount == 0)
        return frames
    }

    private func violation(_ bytes: [UInt8], role: WebSocketFrameDecoder.Role = .client, cap: Int = largeCap, compressed: Bool = false) -> WebSocketProtocolViolation? {
        var decoder = WebSocketFrameDecoder(role: role, maximumFrameSize: cap, allowsCompressedFrames: compressed)
        decoder.append(Data(bytes))
        do {
            _ = try decoder.nextFrame()
            return nil
        } catch let error as WebSocketProtocolViolation {
            return error
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    @Test func encodesRFCUnmaskedAndMaskedHello() {
        let frame = WebSocketFrame(opcode: .text, payload: Data(Self.helloBytes))
        #expect(Array(WebSocketFrameEncoder.encode(frame, maskingKey: nil)) == [0x81, 0x05] + Self.helloBytes)
        #expect(
            Array(WebSocketFrameEncoder.encode(frame, maskingKey: Self.rfcMaskingKey))
                == [0x81, 0x85, 0x37, 0xFA, 0x21, 0x3D, 0x7F, 0x9F, 0x4D, 0x51, 0x58]
        )
    }

    @Test func decodesRFCMaskedHelloAsServer() throws {
        let frames = try decodeAll([0x81, 0x85, 0x37, 0xFA, 0x21, 0x3D, 0x7F, 0x9F, 0x4D, 0x51, 0x58], role: .server)
        #expect(frames == [WebSocketFrame(opcode: .text, payload: Data(Self.helloBytes))])
    }

    @Test func decodesRFCFragmentedMessageAndPing() throws {
        let bytes: [UInt8] = [0x01, 0x03, 0x48, 0x65, 0x6C, 0x89, 0x00, 0x80, 0x02, 0x6C, 0x6F]
        let frames = try decodeAll(bytes)
        #expect(frames == [
            WebSocketFrame(opcode: .text, payload: Data([0x48, 0x65, 0x6C]), isFinal: false),
            WebSocketFrame(opcode: .ping),
            WebSocketFrame(opcode: .continuation, payload: Data([0x6C, 0x6F]))
        ])
    }

    @Test func encodesExtendedLengthHeaders() {
        let cases: [(length: Int, header: [UInt8])] = [
            (125, [0x82, 0x7D]),
            (126, [0x82, 0x7E, 0x00, 0x7E]),
            (256, [0x82, 0x7E, 0x01, 0x00]),
            (65_535, [0x82, 0x7E, 0xFF, 0xFF]),
            (65_536, [0x82, 0x7F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00])
        ]
        for testCase in cases {
            let encoded = WebSocketFrameEncoder.encode(
                WebSocketFrame(opcode: .binary, payload: Data(count: testCase.length)),
                maskingKey: nil
            )
            #expect(Array(encoded.prefix(testCase.header.count)) == testCase.header, "length \(testCase.length)")
            #expect(encoded.count == testCase.header.count + testCase.length)
        }
    }

    @Test func roundTripsMaskedFramesAcrossLengthBoundaries() throws {
        for length in [0, 1, 125, 126, 65_535, 65_536, 70_000] {
            let payload = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            let frame = WebSocketFrame(opcode: .binary, payload: payload, isFinal: length.isMultiple(of: 2), isCompressed: true)
            let wire = WebSocketFrameEncoder.encode(frame, maskingKey: WebSocketMaskingKey.random())
            #expect(try decodeAll(Array(wire), role: .server, compressed: true) == [frame], "length \(length)")
        }
    }

    @Test func decodesIncrementallyByteByByte() throws {
        let first = WebSocketFrame(opcode: .text, payload: Data(repeating: 0x61, count: 300))
        let second = WebSocketFrame(opcode: .pong, payload: Data([1, 2, 3]))
        let wire = WebSocketFrameEncoder.encode(first, maskingKey: nil) + WebSocketFrameEncoder.encode(second, maskingKey: nil)
        var decoder = WebSocketFrameDecoder(role: .client, maximumFrameSize: Self.largeCap)
        var frames: [WebSocketFrame] = []
        for byte in wire {
            decoder.append(Data([byte]))
            while let frame = try decoder.nextFrame() { frames.append(frame) }
        }
        #expect(frames == [first, second])
    }

    @Test func rejectsOversizedFrameFromHeaderAlone() {
        // Only the 64-bit length header is buffered; the cap fails it before
        // any payload arrives.
        #expect(violation([0x82, 0x7F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x01], cap: 1 << 20) == .frameTooLarge)
        #expect(violation([0x82, 0x7F, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) == .frameTooLarge)
        #expect(violation([0x82, 0x7E, 0x01, 0x00], cap: 255) == .frameTooLarge)
    }

    @Test func rejectsReservedBitsWithoutNegotiatedExtension() {
        #expect(violation([0xC1, 0x00]) == .reservedBitsSet)
        #expect(violation([0xA1, 0x00], compressed: true) == .reservedBitsSet)
        #expect(violation([0x91, 0x00], compressed: true) == .reservedBitsSet)
        // RSV1 on a control frame is invalid even with permessage-deflate.
        #expect(violation([0xC9, 0x00], compressed: true) == .reservedBitsSet)
        #expect(violation([0xC1, 0x00], compressed: true) == nil)
    }

    @Test func rejectsMaskingMisuse() {
        #expect(violation([0x81, 0x80, 0, 0, 0, 0]) == .invalidMasking)
        #expect(violation([0x81, 0x00], role: .server) == .invalidMasking)
    }

    @Test func rejectsControlFrameViolationsAndUnknownOpcodes() {
        #expect(violation([0x09, 0x00]) == .fragmentedControlFrame)
        #expect(violation([0x89, 0x7E, 0x00, 0x7E]) == .controlFrameTooLong)
        #expect(violation([0x83, 0x00]) == .unknownOpcode)
        #expect(violation([0x8B, 0x00]) == .unknownOpcode)
    }

    @Test func closeCodesFollowRFC6455() {
        #expect(WebSocketProtocolViolation.frameTooLarge.closeCode == 1009)
        #expect(WebSocketProtocolViolation.messageTooLarge.closeCode == 1009)
        #expect(WebSocketProtocolViolation.invalidTextEncoding.closeCode == 1007)
        #expect(WebSocketProtocolViolation.invalidCompressedData.closeCode == 1007)
        #expect(WebSocketProtocolViolation.reservedBitsSet.closeCode == 1002)
    }
}
