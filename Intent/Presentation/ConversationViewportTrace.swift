import CoreGraphics
import Foundation

@MainActor
final class ConversationViewportTrace {
    private static let maximumRows = 256
    private static let rowEventInterval: TimeInterval = 0.1
    private static let firstSnapshotMilliseconds = 250
    private static let secondSnapshotDelayMilliseconds = 750
    static let idleDelays: [Duration] = [
        .milliseconds(firstSnapshotMilliseconds), .milliseconds(secondSnapshotDelayMilliseconds), .seconds(2)
    ]

    private(set) var visit = UUID().uuidString
    private(set) var isActive = false
    private var frames: [String: CGRect] = [:]
    private var measuredAt: [String: TimeInterval] = [:]
    private var lastRowEvent: [String: TimeInterval] = [:]
    private var endFrame: CGRect?
    var idleTask: Task<Void, Never>?

    func start() {
        guard ConversationTrace.enabled else { return }
        idleTask?.cancel()
        isActive = true
    }

    func stop() {
        guard ConversationTrace.enabled else { return }
        idleTask?.cancel()
        idleTask = nil
        isActive = false
        visit = UUID().uuidString
        frames.removeAll()
        measuredAt.removeAll()
        lastRowEvent.removeAll()
        endFrame = nil
    }

    func row(_ id: String, frame: CGRect, context: @autoclosure () -> String) {
        guard ConversationTrace.enabled else { return }
        if frames[id] == nil, frames.count >= Self.maximumRows, let retired = frames.keys.min() {
            frames[retired] = nil
            measuredAt[retired] = nil
            lastRowEvent[retired] = nil
        }
        frames[id] = frame
        let now = ProcessInfo.processInfo.systemUptime
        measuredAt[id] = now
        guard now - (lastRowEvent[id] ?? 0) >= Self.rowEventInterval else { return }
        lastRowEvent[id] = now
        ConversationTrace.emit("RowGeometry", "\(context()) row=\(id) frame=\(frame)")
    }

    func removeRow(_ id: String) {
        guard ConversationTrace.enabled else { return }
        frames[id] = nil
        measuredAt[id] = nil
        lastRowEvent[id] = nil
    }

    func recordEnd(_ frame: CGRect?) {
        guard ConversationTrace.enabled else { return }
        endFrame = frame
    }

    func summary(viewport: CGRect) -> String {
        let visible = frames.values.filter { $0.intersects(viewport) }.count
        return "trackedRows=\(frames.count) intersectingRows=\(visible) endFrame=\(String(describing: endFrame)) endIntersects=\(endFrame?.intersects(viewport) ?? false)"
    }

    func emitVisibleRows(viewport: CGRect, context: String) {
        for (id, frame) in frames.sorted(by: { $0.key < $1.key }) where frame.intersects(viewport) {
            let age = ProcessInfo.processInfo.systemUptime - (measuredAt[id] ?? 0)
            ConversationTrace.emit("VisibleRowSnapshot", "\(context) row=\(id) frame=\(frame) measurementAgeSeconds=\(age)")
        }
    }
}
