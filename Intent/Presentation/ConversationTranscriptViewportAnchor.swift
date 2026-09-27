import Foundation

/// A late divider may resize an offscreen lazy row. Preserve the first fully
/// visible row's measured offset (or its intersecting oversized message),
/// not merely the identity of a visible target.
/// Each divider revision permits one correction; scrolling remains user-owned.
struct ConversationTranscriptViewportAnchor {
    struct Measurement: Equatable {
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
    }

    private var frames: [String: CGRect] = [:]
    private var divider: String?
    private var initialized = false
    private var pending: Pending?
    private(set) var ownershipRevision = 0

    mutating func record(
        id: String, measurement: Measurement, viewportHeight: CGFloat, preserve: Bool, entryGeneration: Int = 0
    ) -> CGFloat? {
        guard measurement.generation == entryGeneration,
              measurement.ownershipRevision == ownershipRevision else { return nil }
        if pending?.generation != entryGeneration { pending = nil }
        if !initialized || measurement.divider != divider {
            pending = nil
            if initialized, preserve {
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
        guard let pending, pending.id == id else { return nil }
        self.pending = nil
        guard preserve else { return nil }
        let adjustment = measurement.frame.minY - pending.minY
        return adjustment.isFinite && abs(adjustment) > .ulpOfOne ? adjustment : nil
    }

    mutating func remove(id: String, generation: Int = 0, entryGeneration: Int = 0, ownershipRevision: Int = 0) {
        guard generation == entryGeneration, ownershipRevision == self.ownershipRevision else { return }
        frames[id] = nil
        if pending?.id == id { pending = nil }
    }

    mutating func cancelRestoration() {
        ownershipRevision += 1
        pending = nil
        frames.removeAll()
    }

    mutating func reset() {
        cancelRestoration()
        divider = nil
        initialized = false
    }
}
