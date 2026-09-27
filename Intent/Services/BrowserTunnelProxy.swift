import Combine
import Foundation
import Network

@MainActor
protocol BrowserProxySession: AnyObject {
    func forward(_ url: URL) async throws -> URL
    func close() async
}

/// Injectable wire seam; production uses the existing pinned WebSocket actor.
nonisolated protocol BrowserTunnelWebSocket: Sendable {
    func receive() async throws -> URLSessionWebSocketTask.Message
    func send(_ data: Data) async throws
    func disconnect() async
}

extension WebSocketConnection: BrowserTunnelWebSocket {}

/// One browser owns one authenticated tunnel and a bounded set of local ports.
/// Receive never waits for a downstream TCP write: each stream drains separately.
@MainActor
final class BrowserTunnelProxy: BrowserProxySession {
    static let maximumListeners = 8
    static let maximumStreams = 32
    static let maximumBufferedBytes = 8_388_608
    static let maximumControls = 128
    static let openTimeout: Duration = .seconds(15)
    static let idleTimeout: Duration = .seconds(300)

    let socket: any BrowserTunnelWebSocket
    let supportsCredit: Bool
    let writeDownstream: @Sendable (Data?, NWConnection, Bool) async throws -> Void
    let isCurrentConnection: @MainActor () -> Bool
    let queue = DispatchQueue(label: "BrowserTunnel.streams")
    var listeners: [UInt16: BrowserTunnelListener] = [:]
    var streams: [UInt32: BrowserTunnelStream] = [:]
    var nextStreamID: UInt32 = 1
    var bufferedBytes = 0
    var controls: [BrowserTunnelFrame] = []
    var receiveTask: Task<Void, Never>?
    var controlTask: Task<Void, Never>?
    var disconnectTask: Task<Void, Never>?
    var connectionObserver: AnyCancellable?
    private(set) var closed = false

    init(
        socket: any BrowserTunnelWebSocket,
        supportsCredit: Bool,
        writeDownstream: @escaping @Sendable (Data?, NWConnection, Bool) async throws -> Void = { data, connection, eof in
            try await BrowserTunnelTCP.write(data, to: connection, eof: eof)
        },
        isCurrentConnection: @escaping @MainActor () -> Bool = { true }
    ) {
        self.socket = socket
        self.supportsCredit = supportsCredit
        self.writeDownstream = writeDownstream
        self.isCurrentConnection = isCurrentConnection
        receiveTask = Task { [weak self, socket] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    try Task.checkCancellation()
                    self?.receive(try BrowserTunnelFrame.fromDaemon(message))
                }
            } catch {
                self?.stop()
            }
        }
    }

    isolated deinit {
        stop()
    }

    func forward(_ url: URL) async throws -> URL {
        do { return try await forwardURL(url) } catch {
            if Task.isCancelled { stop() }
            throw error
        }
    }

    private func forwardURL(_ url: URL) async throws -> URL {
        try Task.checkCancellation()
        let localPorts = Set(listeners.values.compactMap(\.localPort))
        guard let remotePort = try BrowserTunnelURL.remotePort(for: url, localPorts: localPorts) else { return url }
        guard !closed, isCurrentConnection() else { throw BrowserTunnelError.closed }
        let listener: BrowserTunnelListener
        if let existing = listeners[remotePort] {
            listener = existing
        } else {
            guard listeners.count < Self.maximumListeners else { throw BrowserTunnelError.capacity }
            listener = try BrowserTunnelListener()
            listener.onAccept = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.accept(connection, port: remotePort)
            }
            listener.onFailure = { [weak self] in self?.stop() }
            listeners[remotePort] = listener
        }
        let port = try await listener.ready()
        try Task.checkCancellation()
        guard !closed, isCurrentConnection() else { throw BrowserTunnelError.closed }
        return try BrowserTunnelURL.rewrite(url, localPort: port)
    }

    func close() async {
        stop()
        await disconnectTask?.value
    }

    func stop() {
        guard !closed else { return }
        closed = true
        connectionObserver?.cancel()
        connectionObserver = nil
        receiveTask?.cancel()
        controlTask?.cancel()
        receiveTask = nil
        controlTask = nil
        for listener in listeners.values { listener.cancel() }
        listeners.removeAll()
        for stream in streams.values { stream.cancel() }
        streams.removeAll()
        controls.removeAll()
        bufferedBytes = 0
        disconnectTask = Task { [socket] in await socket.disconnect() }
    }

    func accept(_ connection: NWConnection, port: UInt16) {
        guard !closed, isCurrentConnection(), streams.count < Self.maximumStreams,
              nextStreamID < UInt32.max else {
            connection.cancel()
            return
        }
        // Never reuse an ID: stale callbacks and final CLOSE frames cannot
        // affect a replacement stream. Reopening the browser resets the space.
        let stream = BrowserTunnelStream(id: nextStreamID, port: port, connection: connection)
        nextStreamID += 1
        streams[stream.id] = stream
        connection.start(queue: queue)
        enqueueControl(BrowserTunnelFrame(opcode: .open, streamID: stream.id, payload: BrowserTunnelFrame.bigEndian(port)))
        stream.watchdog = Task { [weak self, weak stream] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.openTimeout) } catch { return }
                guard let self, let stream, self.streams[stream.id] === stream else { return }
                if !stream.flow.opened || stream.lastActivity.duration(to: .now) >= Self.idleTimeout {
                    self.removeStream(stream, notifyDaemon: true)
                    return
                }
            }
        }
    }

    func removeStream(_ stream: BrowserTunnelStream, notifyDaemon: Bool) {
        guard streams[stream.id] === stream else { return }
        streams.removeValue(forKey: stream.id)
        bufferedBytes -= stream.flow.pendingBytes
        stream.cancel()
        if notifyDaemon { enqueueControl(BrowserTunnelFrame(opcode: .close, streamID: stream.id)) }
    }

    func enqueueControl(_ frame: BrowserTunnelFrame) {
        guard !closed else { return }
        if frame.opcode == .credit,
           let index = controls.firstIndex(where: { $0.opcode == .credit && $0.streamID == frame.streamID }) {
            let total = UInt64(controls[index].creditAmount) + UInt64(frame.creditAmount)
            controls[index].payload = BrowserTunnelFrame.bigEndian(UInt32(clamping: total))
            return
        }
        guard controls.count < Self.maximumControls else { stop(); return }
        controls.append(frame)
        guard controlTask == nil else { return }
        controlTask = Task { [weak self, socket] in
            do {
                while let frame = self?.takeControl() {
                    try Task.checkCancellation()
                    try await socket.send(frame.encoded)
                }
            } catch {
                self?.stop()
            }
        }
    }

    private func takeControl() -> BrowserTunnelFrame? {
        guard !closed, !controls.isEmpty else {
            controlTask = nil
            return nil
        }
        return controls.removeFirst()
    }
}
