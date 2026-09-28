import Foundation

extension BrowserTunnelProxy {
    func receive(_ frame: BrowserTunnelFrame) {
        guard !closed, let stream = streams[frame.streamID] else { return }
        do {
            switch frame.opcode {
            case .openOK:
                try stream.flow.confirmOpen()
                stream.lastActivity = .now
                startUpstream(stream)
            case .openError:
                guard !stream.flow.opened else { throw BrowserTunnelError.invalidFrame }
                removeStream(stream, notifyDaemon: false)
            case .data:
                try receiveData(frame, stream: stream)
            case .eof:
                try stream.flow.receiveEOF()
                stream.downstream.append(frame)
                startDownstream(stream)
            case .close:
                receiveClose(frame, stream: stream)
            case .open, .credit:
                throw BrowserTunnelError.invalidFrame
            }
        } catch BrowserTunnelError.capacity {
            removeStream(stream, notifyDaemon: true)
        } catch {
            stop()
        }
    }

    private func receiveClose(_ frame: BrowserTunnelFrame, stream: BrowserTunnelStream) {
        // Drain DATA already received before closing the local socket.
        guard !stream.flow.remoteClosed else { return }
        stream.flow.receiveClose()
        stream.downstream.append(frame)
        startDownstream(stream)
    }

    private func receiveData(_ frame: BrowserTunnelFrame, stream: BrowserTunnelStream) throws {
        guard stream.flow.opened, !stream.flow.remoteEOF, !stream.flow.remoteClosed else {
            throw BrowserTunnelError.invalidFrame
        }
        // Empty payloads carry no application data or credit.
        guard !frame.payload.isEmpty else { return }
        guard frame.payload.count <= Self.maximumBufferedBytes - bufferedBytes else {
            throw BrowserTunnelError.capacity
        }
        try stream.flow.receiveData(frame.payload.count)
        bufferedBytes += frame.payload.count
        stream.downstream.append(frame)
        startDownstream(stream)
    }

    private func startUpstream(_ stream: BrowserTunnelStream) {
        stream.upstreamTask = Task { [weak self, weak stream, socket, connection = stream.connection] in
            do {
                while !Task.isCancelled {
                    let (data, ended) = try await BrowserTunnelTCP.read(connection)
                    try Task.checkCancellation()
                    guard let stream, self?.streams[stream.id] === stream, !stream.flow.remoteClosed else { return }
                    if !data.isEmpty {
                        stream.lastActivity = .now
                        try await socket.send(BrowserTunnelFrame(opcode: .data, streamID: stream.id, payload: data).encoded)
                    }
                    if ended {
                        stream.flow.sentEOF()
                        self?.enqueueControl(BrowserTunnelFrame(opcode: .eof, streamID: stream.id))
                        return
                    }
                }
            } catch {
                if let stream { self?.removeStream(stream, notifyDaemon: true) }
            }
        }
    }

    private func startDownstream(_ stream: BrowserTunnelStream) {
        guard stream.downstreamTask == nil else { return }
        stream.downstreamTask = Task { [weak self, weak stream, writeDownstream] in
            do {
                while let stream, let frame = self?.takeDownstream(stream) {
                    try await writeDownstream(
                        frame.opcode == .data ? frame.payload : nil,
                        stream.connection,
                        frame.opcode != .data
                    )
                    try Task.checkCancellation()
                    self?.delivered(frame, stream: stream)
                }
            } catch {
                if let stream { self?.removeStream(stream, notifyDaemon: true) }
            }
        }
    }

    private func takeDownstream(_ stream: BrowserTunnelStream) -> BrowserTunnelFrame? {
        guard streams[stream.id] === stream, !stream.downstream.isEmpty else {
            stream.downstreamTask = nil
            return nil
        }
        let frame = stream.downstream.removeFirst()
        if frame.opcode == .close {
            // EOF already flushed a write-side FIN. Closing now is safe because
            // all preceding contentProcessed callbacks completed in order.
            removeStream(stream, notifyDaemon: false)
            return nil
        }
        return frame
    }

    private func delivered(_ frame: BrowserTunnelFrame, stream: BrowserTunnelStream) {
        guard streams[stream.id] === stream else { return }
        stream.lastActivity = .now
        guard frame.opcode == .data else { return }
        let credit = stream.flow.delivered(frame.payload.count)
        bufferedBytes -= frame.payload.count
        if supportsCredit, credit > 0 {
            enqueueControl(BrowserTunnelFrame(opcode: .credit, streamID: stream.id, payload: BrowserTunnelFrame.bigEndian(credit)))
        }
    }
}
