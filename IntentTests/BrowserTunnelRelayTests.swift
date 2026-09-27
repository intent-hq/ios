import Foundation
@testable import Intent
import Network
import Testing

// Literal payloads/ports identify stream and protocol boundaries in these fixtures.
// swiftlint:disable no_magic_numbers
@MainActor
struct BrowserTunnelRelayTests {
    private actor Wire: BrowserTunnelWebSocket {
        let incoming = AsyncThrowingStream<URLSessionWebSocketTask.Message, Error>.makeStream()
        private(set) var sent: [BrowserTunnelFrame] = []
        private(set) var disconnected = false

        func receive() async throws -> URLSessionWebSocketTask.Message {
            var iterator = incoming.stream.makeAsyncIterator()
            guard let next = try await iterator.next() else { throw BrowserTunnelError.closed }
            return next
        }

        func send(_ data: Data) throws {
            guard !disconnected else { throw BrowserTunnelError.closed }
            sent.append(try BrowserTunnelFrame(decoding: data))
        }

        func emit(_ frame: BrowserTunnelFrame) {
            incoming.continuation.yield(.data(frame.encoded))
        }

        func disconnect() {
            disconnected = true
            incoming.continuation.finish(throwing: BrowserTunnelError.closed)
        }
    }

    private actor DeliveryGate {
        private var pending: CheckedContinuation<Void, Never>?
        private(set) var writes: [Data?] = []
        private(set) var finishes: [Bool] = []

        func write(_ data: Data?, eof: Bool) async {
            writes.append(data)
            finishes.append(eof)
            if writes.count == 1 {
                await withCheckedContinuation { pending = $0 }
            }
        }

        func release() {
            pending?.resume()
            pending = nil
        }
    }

    private func eventually(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Browser tunnel operation did not complete within its test deadline")
        throw BrowserTunnelError.timedOut
    }

    private func stream(_ id: UInt32, in proxy: BrowserTunnelProxy) throws -> BrowserTunnelStream {
        let stream = BrowserTunnelStream(id: id, port: 8080, connection: NWConnection(host: "127.0.0.1", port: 8080, using: .tcp))
        try stream.flow.confirmOpen()
        proxy.streams[id] = stream
        return stream
    }

    @Test func creditsOnlyAfterDeliveryAndDrainsBeforeEOFAndClose() async throws {
        let wire = Wire()
        let gate = DeliveryGate()
        let proxy = BrowserTunnelProxy(socket: wire, supportsCredit: true, writeDownstream: { data, _, eof in
            await gate.write(data, eof: eof)
        })
        let stream = try stream(1, in: proxy)
        proxy.receive(BrowserTunnelFrame(opcode: .data, streamID: 1, payload: Data([1, 2, 3])))
        proxy.receive(BrowserTunnelFrame(opcode: .eof, streamID: 1))
        proxy.receive(BrowserTunnelFrame(opcode: .close, streamID: 1))
        try await eventually { await gate.writes.count == 1 }
        #expect(await wire.sent.isEmpty)
        #expect(proxy.streams[1] === stream)
        #expect(proxy.bufferedBytes == 3)
        await gate.release()
        try await eventually {
            let credited = await wire.sent.contains { $0.opcode == .credit }
            return proxy.streams.isEmpty && credited
        }
        #expect(await gate.writes == [Data([1, 2, 3]), nil])
        #expect(await gate.finishes == [false, true])
        #expect(proxy.bufferedBytes == 0)
        #expect(await wire.sent.first(where: { $0.opcode == .credit })?.creditAmount == 3)
        await proxy.close()
        #expect(await wire.disconnected)
    }

    @Test func legacyDaemonNeverReceivesCredit() async throws {
        let wire = Wire()
        let proxy = BrowserTunnelProxy(socket: wire, supportsCredit: false, writeDownstream: { _, _, _ in })
        let stream = try stream(1, in: proxy)
        proxy.receive(BrowserTunnelFrame(opcode: .data, streamID: 1, payload: Data([1])))
        try await eventually { stream.flow.pendingBytes == 0 }
        #expect(await wire.sent.isEmpty)
        await proxy.close()
    }

    @Test func overflowClosesOnlyTheOffendingStreamAndCloseCleansEverything() async throws {
        let wire = Wire()
        let gate = DeliveryGate()
        let proxy = BrowserTunnelProxy(socket: wire, supportsCredit: true, writeDownstream: { data, _, eof in
            await gate.write(data, eof: eof)
        })
        _ = try stream(1, in: proxy)
        let sibling = try stream(2, in: proxy)
        proxy.receive(BrowserTunnelFrame(opcode: .data, streamID: 1, payload: Data(repeating: 1, count: BrowserTunnelFlow.maximumQueuedBytes)))
        try await eventually { await gate.writes.count == 1 }
        proxy.receive(BrowserTunnelFrame(opcode: .data, streamID: 1, payload: Data([2])))
        #expect(proxy.streams[1] == nil)
        #expect(proxy.streams[2] === sibling)
        #expect(!proxy.closed)
        #expect(proxy.bufferedBytes == 0)
        await gate.release()
        try await eventually { await wire.sent.contains { $0.opcode == .close && $0.streamID == 1 } }
        await proxy.close()
        #expect(proxy.streams.isEmpty)
        #expect(proxy.listeners.isEmpty)
        #expect(proxy.controls.isEmpty)
        #expect(await wire.disconnected)
    }

    @Test func forwardReusesListenerAndCancellationClosesIt() async throws {
        let wire = Wire()
        let proxy = BrowserTunnelProxy(socket: wire, supportsCredit: true)
        let url = try #require(URL(string: "http://daemon.localhost:8080/a?q=1#fragment"))
        let first = try await proxy.forward(url)
        #expect(try await proxy.forward(url) == first)
        #expect(try await proxy.forward(first) == first)
        let external = try #require(URL(string: "https://example.com/path"))
        #expect(try await proxy.forward(external) == external)
        #expect(proxy.listeners.count == 1)
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await proxy.forward(url)
        }
        do {
            _ = try await cancelled.value
            Issue.record("Cancelled navigation must not return a live forward")
        } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(proxy.closed)
        #expect(proxy.listeners.isEmpty)
        await proxy.close()
        #expect(await wire.disconnected)
    }

    @Test func realLoopbackWaitsForOpenAndRelaysHalfClosedTCP() async throws {
        let wire = Wire()
        let proxy = BrowserTunnelProxy(socket: wire, supportsCredit: true)
        let url = try await proxy.forward(#require(URL(string: "http://daemon.localhost:8080/")))
        let port = try #require(NWEndpoint.Port(rawValue: UInt16(#require(url.port))))
        let local = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        local.start(queue: DispatchQueue(label: "BrowserTunnelRelayTests.client"))
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            local.cancel()
        }
        defer { timeout.cancel(); local.cancel() }
        let request = Data("GET / HTTP/1.0\r\n\r\n".utf8)
        try await BrowserTunnelTCP.write(request, to: local, eof: true)
        try await eventually { await wire.sent.contains { $0.opcode == .open } }
        let opened = try #require(await wire.sent.first { $0.opcode == .open })
        #expect(await wire.sent.allSatisfy { $0.opcode == .open })
        await wire.emit(BrowserTunnelFrame(opcode: .openOK, streamID: opened.streamID))
        try await eventually { await wire.sent.contains { $0.opcode == .eof } }
        let uploaded = await wire.sent.filter { $0.opcode == .data }.reduce(Data()) { $0 + $1.payload }
        #expect(uploaded == request)
        let response = Data("HTTP/1.0 200 OK\r\n\r\nhello".utf8)
        await wire.emit(BrowserTunnelFrame(opcode: .data, streamID: opened.streamID, payload: response))
        await wire.emit(BrowserTunnelFrame(opcode: .eof, streamID: opened.streamID))
        var downloaded = Data()
        while true {
            let (chunk, ended) = try await BrowserTunnelTCP.read(local)
            downloaded.append(chunk)
            if ended { break }
        }
        #expect(downloaded == response)
        await wire.emit(BrowserTunnelFrame(opcode: .close, streamID: opened.streamID))
        try await eventually { proxy.streams.isEmpty }
        await proxy.close()
    }

    @Test func dataBeforeOpenAndDaemonOnlyDirectionViolationsCloseTunnel() async throws {
        let wire = Wire()
        let proxy = BrowserTunnelProxy(socket: wire, supportsCredit: true)
        let pending = BrowserTunnelStream(id: 1, port: 8080, connection: NWConnection(host: "127.0.0.1", port: 8080, using: .tcp))
        proxy.streams[1] = pending
        #expect(pending.upstreamTask == nil)
        proxy.receive(BrowserTunnelFrame(opcode: .data, streamID: 1, payload: Data([1])))
        #expect(proxy.closed)
        await proxy.close()
        #expect(await wire.disconnected)

        let otherWire = Wire()
        let other = BrowserTunnelProxy(socket: otherWire, supportsCredit: true)
        await otherWire.emit(BrowserTunnelFrame(opcode: .credit, streamID: 99, payload: Data([0, 0, 0, 1])))
        try await eventually { other.closed }
        await other.close()
    }
}
// swiftlint:enable no_magic_numbers
