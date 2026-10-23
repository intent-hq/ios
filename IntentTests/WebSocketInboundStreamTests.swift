import Foundation
@testable import Intent
import Testing

/// The pure receive path behind `WebSocketConnection.receive()`.
struct WebSocketInboundStreamTests {
    private typealias Stream = WebSocketConnection.InboundStream

    private static let compressedHello: [UInt8] = [0xF2, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0x00]

    private func stream(cap: Int = 1 << 20, compressed: Bool = false) throws -> Stream {
        let deflate = compressed ? try PerMessageDeflate(parameters: PerMessageDeflateParameters()) : nil
        return Stream(maximumMessageSize: cap, deflate: deflate, diagnostics: DiagnosticStore(storage: DiagnosticTestStorage()))
    }

    private func wire(_ frames: [WebSocketFrame]) -> Data {
        frames.reduce(into: Data()) { $0.append(WebSocketFrameEncoder.encode($1, maskingKey: nil)) }
    }

    private func events(_ frames: [WebSocketFrame], in stream: inout Stream) throws -> [String] {
        stream.append(wire(frames))
        var described: [String] = []
        while let event = try stream.nextEvent() {
            switch event {
            case .message(.string(let text)): described.append("text:\(text)")
            case .message(.data(let data)): described.append("data:\(data.count)")
            case .message: described.append("unknown")
            case .ping(let payload): described.append("ping:\(payload.count)")
            case .pong(let payload): described.append("pong:\(payload.count)")
            case let .close(code, reason): described.append("close:\(code):\(reason)")
            }
        }
        return described
    }

    private func violation(_ frames: [WebSocketFrame], compressed: Bool = false, cap: Int = 1 << 20) throws -> WebSocketConnection.MessageAssemblyError? {
        var stream = try stream(cap: cap, compressed: compressed)
        do {
            _ = try events(frames, in: &stream)
            return nil
        } catch let error as WebSocketConnection.MessageAssemblyError {
            return error
        }
    }

    @Test func deliversPlainAndFragmentedMessagesWithInterleavedControlFrames() throws {
        var stream = try stream()
        let events = try events([
            WebSocketFrame(opcode: .text, payload: Data("He".utf8), isFinal: false),
            WebSocketFrame(opcode: .ping, payload: Data([9])),
            WebSocketFrame(opcode: .continuation, payload: Data("llo".utf8)),
            WebSocketFrame(opcode: .binary, payload: Data(count: 3)),
            WebSocketFrame(opcode: .pong, payload: Data([1, 2]))
        ], in: &stream)
        #expect(events == ["ping:1", "text:Hello", "data:3", "pong:2"])
    }

    @Test func inflatesCompressedMessagesIncludingFragmented() throws {
        var stream = try stream(compressed: true)
        let first = Array(Self.compressedHello.prefix(3))
        let rest = Array(Self.compressedHello.dropFirst(3))
        let events = try events([
            WebSocketFrame(opcode: .text, payload: Data(Self.compressedHello), isCompressed: true),
            WebSocketFrame(opcode: .text, payload: Data(first), isFinal: false, isCompressed: true),
            WebSocketFrame(opcode: .continuation, payload: Data(rest)),
            WebSocketFrame(opcode: .text, payload: Data("plain".utf8))
        ], in: &stream)
        // The RFC sample is a literal-only block, so it inflates to "Hello"
        // whatever the retained context; RSV1 only on the first fragment.
        #expect(events == ["text:Hello", "text:Hello", "text:plain"])
    }

    @Test func rejectsFragmentationViolations() throws {
        #expect(try violation([WebSocketFrame(opcode: .continuation)]) == .protocolViolation(.unexpectedContinuation))
        #expect(try violation([
            WebSocketFrame(opcode: .text, isFinal: false),
            WebSocketFrame(opcode: .binary)
        ]) == .protocolViolation(.unexpectedDataFrame))
        #expect(try violation([
            WebSocketFrame(opcode: .text, payload: Data(Self.compressedHello.prefix(3)), isFinal: false, isCompressed: true),
            WebSocketFrame(opcode: .continuation, payload: Data(Self.compressedHello.dropFirst(3)), isCompressed: true)
        ], compressed: true) == .protocolViolation(.reservedBitsSet))
    }

    @Test func rejectsCompressedFramesWithoutNegotiation() throws {
        #expect(try violation([WebSocketFrame(opcode: .text, payload: Data(Self.compressedHello), isCompressed: true)])
            == .protocolViolation(.reservedBitsSet))
    }

    @Test func capsBufferedAndInflatedMessageSize() throws {
        #expect(try violation([
            WebSocketFrame(opcode: .binary, payload: Data(count: 60), isFinal: false),
            WebSocketFrame(opcode: .continuation, payload: Data(count: 60))
        ], cap: 100) == .protocolViolation(.messageTooLarge))
        let bomb = try #require(try PerMessageDeflate(parameters: PerMessageDeflateParameters()).compress(Data(count: 10_000)))
        #expect(try violation([WebSocketFrame(opcode: .binary, payload: bomb, isCompressed: true)], compressed: true, cap: 1000)
            == .protocolViolation(.messageTooLarge))
    }

    @Test func validatesUTF8AfterInflation() throws {
        let invalid = try #require(try PerMessageDeflate(parameters: PerMessageDeflateParameters()).compress(Data([0xFF, 0xFE])))
        #expect(try violation([WebSocketFrame(opcode: .text, payload: invalid, isCompressed: true)], compressed: true) == .invalidTextEncoding)
    }

    @Test func parsesCloseFrames() throws {
        var stream = try stream()
        #expect(try events([WebSocketFrame(opcode: .close)], in: &stream) == ["close:1005:Connection closed"])
        #expect(try events([WebSocketFrame(opcode: .close, payload: Data([0x03, 0xE8]) + Data("bye".utf8))], in: &stream)
            == ["close:1000:bye"])
        #expect(try violation([WebSocketFrame(opcode: .close, payload: Data([0x03]))]) == .protocolViolation(.invalidCloseFrame))
    }

    @Test func echoesOnlySendableCloseCodes() {
        #expect(WebSocketConnection.echoedCloseCode(1001) == 1001)
        #expect(WebSocketConnection.echoedCloseCode(4000) == 4000)
        #expect(WebSocketConnection.echoedCloseCode(1005) == 1000)
        #expect(WebSocketConnection.echoedCloseCode(1006) == 1000)
        #expect(WebSocketConnection.echoedCloseCode(1015) == 1000)
        #expect(WebSocketConnection.echoedCloseCode(5000) == 1000)
    }
}
