import Foundation
@testable import Intent
import Testing

// These are literal wire vectors from protocol §1.4.
struct BrowserTunnelFrameTests {
    @Test func encodesNetworkByteOrder() throws {
        let frame = BrowserTunnelFrame(opcode: .open, streamID: 0x0102_0304, payload: BrowserTunnelFrame.bigEndian(UInt16(8080)))
        #expect(frame.encoded == Data([1, 1, 2, 3, 4, 0x1F, 0x90]))
        #expect(try BrowserTunnelFrame(decoding: frame.encoded) == frame)
        let credit = BrowserTunnelFrame(opcode: .credit, streamID: 9, payload: BrowserTunnelFrame.bigEndian(UInt32(65_536)))
        #expect(credit.encoded == Data([7, 0, 0, 0, 9, 0, 1, 0, 0]))
    }

    @Test func rejectsMalformedFrames() {
        let invalid: [[UInt8]] = [
            [], [1], [4, 0, 0, 1], [8, 0, 0, 0, 1],
            [1, 0, 0, 0, 1], [1, 0, 0, 0, 1, 80], [1, 0, 0, 0, 1, 0, 80, 0],
            [2, 0, 0, 0, 1, 0], [3, 0, 0, 0, 1, 0xFF],
            [5, 0, 0, 0, 1, 0], [6, 0, 0, 0, 1, 0],
            [7, 0, 0, 0, 1, 0, 0, 0, 0], [7, 0, 0, 0, 1, 1]
        ]
        for bytes in invalid {
            #expect(throws: BrowserTunnelError.invalidFrame) { try BrowserTunnelFrame(decoding: Data(bytes)) }
        }
        #expect(throws: BrowserTunnelError.invalidFrame) {
            try BrowserTunnelFrame(decoding: Data(repeating: 4, count: BrowserTunnelFrame.maximumMessageSize + 1))
        }
    }

    @Test func acceptsArbitraryBinaryAndRejectsWrongDirection() throws {
        let payload = Data([0, 0xFF, 0x80, 0, 10])
        let frame = BrowserTunnelFrame(opcode: .data, streamID: 17, payload: payload)
        #expect(try BrowserTunnelFrame.fromDaemon(.data(frame.encoded)).payload == payload)
        #expect(throws: BrowserTunnelError.invalidFrame) { try BrowserTunnelFrame.fromDaemon(.string("hello")) }
        for frame in [
            BrowserTunnelFrame(opcode: .open, streamID: 1, payload: Data([0, 80])),
            BrowserTunnelFrame(opcode: .credit, streamID: 1, payload: Data([0, 0, 0, 1]))
        ] {
            #expect(throws: BrowserTunnelError.invalidFrame) { try BrowserTunnelFrame.fromDaemon(.data(frame.encoded)) }
        }
    }

    @Test func creditRequiresNumericCompatibleVersion() {
        for version in ["10.4", "10.10", "11.0", "100.0"] {
            #expect(BrowserTunnelFrame.supportsCredit(protocolVersion: version))
        }
        for version in [nil, "", "10.3", "9.99", "10", "10.4.1", "10.x", "10.-4", " 10.4", "10.٤"] {
            #expect(!BrowserTunnelFrame.supportsCredit(protocolVersion: version))
        }
    }

    @Test func flowWaitsForOpenAndDeliveryBeforeReleasingCapacity() throws {
        var flow = BrowserTunnelFlow()
        #expect(throws: BrowserTunnelError.invalidFrame) { try flow.receiveData(1) }
        try flow.confirmOpen()
        try flow.receiveData(BrowserTunnelFlow.maximumQueuedBytes)
        #expect(flow.pendingBytes == BrowserTunnelFlow.maximumQueuedBytes)
        #expect(throws: BrowserTunnelError.capacity) { try flow.receiveData(1) }
        #expect(flow.delivered(BrowserTunnelFlow.maximumQueuedBytes) == UInt32(BrowserTunnelFlow.maximumQueuedBytes))
        #expect(flow.pendingBytes == 0)
        #expect(flow.pendingFrames == 0)
        try flow.receiveEOF()
        #expect(!flow.localEOF)
        #expect(throws: BrowserTunnelError.invalidFrame) { try flow.receiveData(1) }
        flow.sentEOF()
        #expect(flow.localEOF)
        flow.receiveClose()
        #expect(flow.remoteClosed)
    }

    @Test func boundsTinyFramesIndependentlyOfByteBudget() throws {
        var flow = BrowserTunnelFlow()
        try flow.confirmOpen()
        for _ in 0..<BrowserTunnelFlow.maximumQueuedFrames { try flow.receiveData(1) }
        #expect(throws: BrowserTunnelError.capacity) { try flow.receiveData(1) }
        #expect(flow.delivered(1) == 1)
        try flow.receiveData(1)
        #expect(flow.pendingBytes == BrowserTunnelFlow.maximumQueuedFrames)
    }
}
