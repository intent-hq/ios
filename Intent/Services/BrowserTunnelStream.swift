import Foundation
import Network

@MainActor
final class BrowserTunnelStream {
    let id: UInt32
    let port: UInt16
    let connection: NWConnection
    var flow = BrowserTunnelFlow()
    var downstream: [BrowserTunnelFrame] = []
    var upstreamTask: Task<Void, Never>?
    var downstreamTask: Task<Void, Never>?
    var watchdog: Task<Void, Never>?
    var lastActivity = ContinuousClock.now

    init(id: UInt32, port: UInt16, connection: NWConnection) {
        self.id = id
        self.port = port
        self.connection = connection
    }

    isolated deinit {
        connection.cancel()
        upstreamTask?.cancel()
        downstreamTask?.cancel()
        watchdog?.cancel()
    }

    func cancel() {
        connection.cancel()
        upstreamTask?.cancel()
        downstreamTask?.cancel()
        watchdog?.cancel()
        upstreamTask = nil
        downstreamTask = nil
        watchdog = nil
        downstream.removeAll()
    }
}
