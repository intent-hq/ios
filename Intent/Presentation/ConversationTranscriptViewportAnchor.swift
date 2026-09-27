import CoreGraphics
import Foundation

/// A late divider may resize an offscreen lazy row. Preserve the first fully
/// visible row's measured offset (or its intersecting oversized message),
/// not merely the identity of a visible target.
/// Each divider revision permits one correction; scrolling remains user-owned.
struct ConversationTranscriptViewportAnchor {
    private static let maximumRestorationEvents = 8

    struct Position {
        let id: String
        let minY: CGFloat
    }

    nonisolated struct Measurement: Equatable, Sendable {
        let frame: CGRect
        let divider: String?
        let generation: Int
        let ownershipRevision: Int

        init(frame: CGRect, divider: String?, generation: Int = 0, ownershipRevision: Int = 0) {
            self.frame = frame
            self.divider = divider
            self.generation = generation
            self.ownershipRevision = ownershipRevision
        }
    }

    private struct Pending {
        let id: String
        let minY: CGFloat
        let generation: Int
        var isReappearance = false
    }

    private var frames: [String: CGRect] = [:]
    private var divider: String?
    private var initialized = false
    private var pending: Pending?
    private var restorationEvents: [String] = []
    private(set) var visiblePosition: Position?
    private(set) var ownershipRevision = 0

    var restorationSummary: String { restorationEvents.joined(separator: "; ") }

    mutating func record(
        id: String, measurement: Measurement, viewportHeight: CGFloat, preserve: Bool, entryGeneration: Int = 0
    ) -> CGFloat? {
        guard measurement.generation == entryGeneration,
              measurement.ownershipRevision == ownershipRevision else { return nil }
        if pending?.generation != entryGeneration { pending = nil }
        if !initialized || measurement.divider != divider {
            if pending?.isReappearance != true {
                pending = nil
            }
            if pending == nil, initialized, preserve {
                let visible = frames.filter { $0.value.minY < viewportHeight && $0.value.maxY > 0 && $0.value.height > 0 }
                let full = visible.filter { $0.value.minY >= 0 && $0.value.maxY <= viewportHeight }
                pending = (full.isEmpty ? visible : full)
                    .min { $0.value.minY < $1.value.minY }
                    .map { Pending(id: $0.key, minY: $0.value.minY, generation: entryGeneration) }
            }
            initialized = true
            divider = measurement.divider
        }
        frames[id] = measurement.frame
        let visible = frames.filter { $0.value.minY < viewportHeight && $0.value.maxY > 0 && $0.value.height > 0 }
        let full = visible.filter { $0.value.minY >= 0 && $0.value.maxY <= viewportHeight }
        if let first = (full.isEmpty ? visible : full).min(by: { $0.value.minY < $1.value.minY }) {
            visiblePosition = Position(id: first.key, minY: first.value.minY)
        }
        guard let pending, pending.id == id else { return nil }
        let adjustment = measurement.frame.minY - pending.minY
        if pending.isReappearance, !canConsumeRestoration(measurement, viewportHeight: viewportHeight, preserve: preserve, adjustment: adjustment) {
            return nil
        }
        self.pending = nil
        guard preserve else { return nil }
        return adjustment.isFinite && abs(adjustment) > .ulpOfOne ? adjustment : nil
    }

    mutating func remove(id: String, generation: Int = 0, entryGeneration: Int = 0, ownershipRevision: Int = 0) {
        guard generation == entryGeneration, ownershipRevision == self.ownershipRevision else { return }
        frames[id] = nil
        // A retained target can leave the lazy stack while it is rehosted.
        // The transcript owner cancels a deleted target or a later gesture.
        if pending?.id == id, pending?.isReappearance == true { recordRestorationEvent("derealized=\(id)") }
        if pending?.id == id, pending?.isReappearance != true { pending = nil }
    }

    mutating func cancelRestoration() {
        if pending?.isReappearance == true { recordRestorationEvent("cancelled-by-owner") }
        ownershipRevision += 1
        pending = nil
        frames.removeAll()
        visiblePosition = nil
    }

    mutating func restore(_ position: Position, generation: Int) {
        restorationEvents = ["restore=\(position.id) y=\(position.minY) generation=\(generation) owner=\(ownershipRevision)"]
        pending = Pending(id: position.id, minY: position.minY, generation: generation, isReappearance: true)
    }

    private mutating func recordRestorationEvent(_ event: String) {
        restorationEvents.append(event)
        if restorationEvents.count > Self.maximumRestorationEvents { restorationEvents.remove(at: 1) }
    }

    private mutating func canConsumeRestoration(_ measurement: Measurement, viewportHeight: CGFloat, preserve: Bool, adjustment: CGFloat) -> Bool {
        recordRestorationEvent("measure=\(measurement.frame) viewport=\(viewportHeight) preserve=\(preserve)")
        // Rehosting can report unavailable geometry before realizing the row.
        let frame = measurement.frame
        guard viewportHeight.isFinite, viewportHeight > 0, !frame.isInfinite,
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.size.width.isFinite, frame.size.height.isFinite,
              frame.size.width > 0, frame.size.height > 0,
              frame.maxX.isFinite, frame.maxY.isFinite,
              frame.maxY > 0, frame.minY < viewportHeight else { return false }
        // A measurement at the saved offset can precede the coarse scrollTo.
        // Keep its correction until that scroll has moved the row.
        if preserve, abs(adjustment) <= .ulpOfOne {
            recordRestorationEvent("awaiting-coarse-move")
            return false
        }
        recordRestorationEvent(preserve ? "adjust=\(adjustment)" : "yielded")
        return true
    }

    mutating func reset() {
        cancelRestoration()
        divider = nil
        initialized = false
    }
}
