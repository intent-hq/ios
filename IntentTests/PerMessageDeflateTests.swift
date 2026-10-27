import Foundation
@testable import Intent
import Testing

/// RFC 7692 permessage-deflate codec: §7.2.3 sample vectors, context modes,
/// threshold, and the inflate size cap.
struct PerMessageDeflateTests {
    private static let hello = Data("Hello".utf8)
    private static let compressedHello: [UInt8] = [0xF2, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0x00]
    private static let sharedContextHello: [UInt8] = [0xF2, 0x00, 0x11, 0x00, 0x00]
    private static let cap = 1 << 20

    private func codec(_ configure: (inout PerMessageDeflateParameters) -> Void = { _ in }, threshold: Int = 0) throws -> PerMessageDeflate {
        var parameters = PerMessageDeflateParameters()
        configure(&parameters)
        return try PerMessageDeflate(parameters: parameters, compressionThreshold: threshold)
    }

    @Test func compressesRFCHelloWithSharedContext() throws {
        let deflate = try codec()
        #expect(try Array(#require(deflate.compress(Self.hello))) == Self.compressedHello)
        #expect(try Array(#require(deflate.compress(Self.hello))) == Self.sharedContextHello)
    }

    @Test func inflatesRFCSampleMessages() throws {
        let vectors: [[UInt8]] = [
            Self.compressedHello,
            // §7.2.3.3 stored (uncompressed) DEFLATE block.
            [0x00, 0x05, 0x00, 0xFA, 0xFF, 0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x00],
            // §7.2.3.4 BFINAL set.
            [0xF3, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0x00, 0x00],
            // §7.2.3.5 two DEFLATE blocks in one message.
            [0xF2, 0x48, 0x05, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xCA, 0xC9, 0xC9, 0x07, 0x00]
        ]
        for vector in vectors {
            let inflater = try codec()
            #expect(try inflater.decompress(Data(vector), maximumSize: Self.cap) == Self.hello, "\(vector)")
        }
    }

    @Test func inflatesSharedContextSequenceAndAfterFinalBlock() throws {
        let inflater = try codec()
        #expect(try inflater.decompress(Data(Self.compressedHello), maximumSize: Self.cap) == Self.hello)
        #expect(try inflater.decompress(Data(Self.sharedContextHello), maximumSize: Self.cap) == Self.hello)
        // A BFINAL message ends the stream; the next message starts fresh.
        #expect(try inflater.decompress(Data([0xF3, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0x00, 0x00]), maximumSize: Self.cap) == Self.hello)
        #expect(try inflater.decompress(Data(Self.compressedHello), maximumSize: Self.cap) == Self.hello)
    }

    @Test func finalBlockKeepsWindowUnderContextTakeover() throws {
        let finalHello = Data([0xF3, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0x00])
        // After a BFINAL message the server may still refer back to it
        // (RFC 7692 §7.2.3.4); the RFC's shared-context "Hello" does so.
        // Both the bare final block and the RFC's padded form must work.
        for message in [finalHello, finalHello + [0x00]] {
            let inflater = try codec()
            #expect(try inflater.decompress(message, maximumSize: Self.cap) == Self.hello)
            #expect(try inflater.decompress(Data(Self.sharedContextHello), maximumSize: Self.cap) == Self.hello)
            #expect(try inflater.decompress(Data(Self.sharedContextHello), maximumSize: Self.cap) == Self.hello)
        }

        // Without context takeover there is no window to refer back to.
        let isolated = try codec { $0.serverNoContextTakeover = true }
        #expect(try isolated.decompress(finalHello, maximumSize: Self.cap) == Self.hello)
        #expect(throws: WebSocketProtocolViolation.self) {
            try isolated.decompress(Data(Self.sharedContextHello), maximumSize: Self.cap)
        }
    }

    @Test func clientNoContextTakeoverResetsPerMessage() throws {
        let deflate = try codec { $0.clientNoContextTakeover = true }
        #expect(try Array(#require(deflate.compress(Self.hello))) == Self.compressedHello)
        #expect(try Array(#require(deflate.compress(Self.hello))) == Self.compressedHello)
    }

    @Test func roundTripsLargeMessagesInBothContextModes() throws {
        let payload = Data(String(repeating: #"{"jsonrpc":"2.0","method":"events.event","params":{"n":42}}"#, count: 4000).utf8)
        for noContextTakeover in [false, true] {
            let sender = try codec { $0.clientNoContextTakeover = noContextTakeover }
            let receiver = try codec { $0.serverNoContextTakeover = noContextTakeover }
            for _ in 0..<3 {
                let compressed = try #require(sender.compress(payload))
                #expect(compressed.count < payload.count / 10)
                #expect(try receiver.decompress(compressed, maximumSize: Self.cap) == payload)
            }
        }
    }

    @Test func roundTripsEmptyAndIncompressiblePayloads() throws {
        let sender = try codec()
        let receiver = try codec()
        var generator = SystemRandomNumberGenerator()
        let noise = Data((0..<50_000).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        for payload in [Data(), noise, Self.hello] {
            let compressed = try #require(sender.compress(payload))
            #expect(try receiver.decompress(compressed, maximumSize: Self.cap) == payload)
        }
    }

    @Test func thresholdLeavesSmallMessagesUncompressed() throws {
        let deflate = try PerMessageDeflate(parameters: PerMessageDeflateParameters())
        #expect(deflate.compressionThreshold == 1024)
        #expect(deflate.compressIfWorthwhile(Data(count: 1023)) == nil)
        #expect(deflate.compressIfWorthwhile(Data(count: 1024)) != nil)
    }

    @Test func eightBitClientWindowSendsUncompressed() throws {
        let deflate = try codec { $0.clientMaxWindowBits = 8 }
        #expect(deflate.compressIfWorthwhile(Data(count: 4096)) == nil)
        // Inflating server messages still works.
        #expect(try deflate.decompress(Data(Self.compressedHello), maximumSize: Self.cap) == Self.hello)
    }

    @Test func inflateStopsAtSizeCapForZipBomb() throws {
        let sender = try codec()
        let bomb = try #require(sender.compress(Data(count: 64 << 20)))
        #expect(bomb.count < 128 * 1024)
        let receiver = try codec()
        #expect(throws: WebSocketProtocolViolation.messageTooLarge) {
            try receiver.decompress(bomb, maximumSize: Self.cap)
        }
    }

    @Test func exactCapIsAllowed() throws {
        let payload = Data(repeating: 0x7A, count: 100_000)
        let compressed = try #require(try codec().compress(payload))
        #expect(try codec().decompress(compressed, maximumSize: payload.count) == payload)
        #expect(throws: WebSocketProtocolViolation.messageTooLarge) {
            try codec().decompress(compressed, maximumSize: payload.count - 1)
        }
    }

    @Test func corruptInputFails() throws {
        #expect(throws: WebSocketProtocolViolation.invalidCompressedData) {
            try codec().decompress(Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF]), maximumSize: Self.cap)
        }
    }
}
