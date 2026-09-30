import Foundation

/// Per-stream bookkeeping includes the write currently in flight. Credit is
/// returned by delivered(), never when a DATA frame is merely received.
nonisolated struct BrowserTunnelFlow {
    static let maximumQueuedFrames = 128
    static let maximumQueuedBytes = BrowserTunnelFrame.maximumPayloadSize

    private(set) var opened = false
    private(set) var remoteEOF = false
    private(set) var remoteClosed = false
    private(set) var localEOF = false
    private(set) var pendingBytes = 0
    private(set) var pendingFrames = 0

    mutating func confirmOpen() throws {
        guard !opened, !remoteClosed else { throw BrowserTunnelError.invalidFrame }
        opened = true
    }

    mutating func receiveData(_ count: Int) throws {
        guard opened, !remoteEOF, !remoteClosed, count >= 0 else { throw BrowserTunnelError.invalidFrame }
        guard pendingFrames < Self.maximumQueuedFrames,
              count <= Self.maximumQueuedBytes - pendingBytes else { throw BrowserTunnelError.capacity }
        pendingBytes += count
        pendingFrames += 1
    }

    mutating func delivered(_ count: Int) -> UInt32 {
        precondition(count >= 0 && count <= pendingBytes && pendingFrames > 0)
        pendingBytes -= count
        pendingFrames -= 1
        return UInt32(count)
    }

    mutating func receiveEOF() throws {
        guard opened, !remoteEOF, !remoteClosed else { throw BrowserTunnelError.invalidFrame }
        remoteEOF = true
    }

    mutating func receiveClose() {
        remoteClosed = true
    }

    mutating func sentEOF() {
        localEOF = true
    }
}
