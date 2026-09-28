import CoreGraphics
import Foundation

/// A late divider may resize an offscreen lazy row. Preserve the first fully
/// visible row's measured offset (or its intersecting oversized message),
/// not merely the identity of a visible target.
/// Each divider revision permits one correction; scrolling remains user-owned.
struct ConversationTranscriptViewportAnchor {
    private static let maximumRestorationEvents = 8
    private static let landingTolerance: CGFloat = 0.5

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
        var coarseScrollIssued = false
    }

    private var frames: [String: CGRect] = [:]
    private var divider: String?
    private var initialized = false
    private var pending: Pending?
    private var restorationEvents: [String] = []
    private var restorationTarget: String?
    private var currentMessageIDs: Set<String> = []
    private var hasEstablishedCurrentMessages = false
    private(set) var visiblePosition: Position?
    private(set) var ownershipRevision = 0

    var restorationSummary: String { restorationEvents.joined(separator: "; ") }

    mutating func record(
        id: String,
        measurement: Measurement,
        viewportHeight: CGFloat,
        preserve: Bool,
        entryGeneration: Int = 0,
        scrollGeometry: ConversationTranscriptScrollPolicy.ViewportGeometry? = nil
    ) -> CGFloat? {
        guard measurement.generation == entryGeneration,
              measurement.ownershipRevision == ownershipRevision,
              !hasEstablishedCurrentMessages || currentMessageIDs.contains(id) else { return nil }
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
        guard let pending, pending.id == id else {
            if restorationTarget == id { recordRestorationEvent("after=\(measurement.frame) offset=\(String(describing: scrollGeometry?.contentOffsetY))") }
            return nil
        }
        let adjustment = measurement.frame.minY - pending.minY
        if pending.isReappearance, !canConsumeRestoration(measurement, viewportHeight: viewportHeight, preserve: preserve, pending: pending, scrollGeometry: scrollGeometry) {
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
        restorationTarget = nil
        ownershipRevision += 1
        pending = nil
        frames.removeAll()
        visiblePosition = nil
    }

    mutating func retainMessages(withIDs messageIDs: Set<String>) {
        guard !hasEstablishedCurrentMessages || currentMessageIDs != messageIDs else { return }
        currentMessageIDs = messageIDs
        hasEstablishedCurrentMessages = true
        if let pending, !messageIDs.contains(pending.id) { cancelRestoration() }
        frames = frames.filter { messageIDs.contains($0.key) }
        if let visiblePosition, !messageIDs.contains(visiblePosition.id) { self.visiblePosition = nil }
    }

    mutating func restore(_ position: Position, generation: Int) {
        restorationEvents = ["restore=\(position.id) y=\(position.minY) generation=\(generation) owner=\(ownershipRevision)"]
        restorationTarget = position.id
        pending = Pending(id: position.id, minY: position.minY, generation: generation, isReappearance: true)
    }

    mutating func retainedScrollIssued(target: String, generation: Int, ownershipRevision: Int) {
        guard let pending, pending.isReappearance, !pending.coarseScrollIssued,
              pending.id == target, pending.generation == generation,
              ownershipRevision == self.ownershipRevision else { return }
        // The published token rejects pre-command callbacks. Command return
        // does not mean the lazy stack has applied the requested alignment.
        self.ownershipRevision += 1
        self.pending?.coarseScrollIssued = true
        frames.removeAll()
        visiblePosition = nil
        recordRestorationEvent("coarse-issued owner=\(self.ownershipRevision)")
    }

    private mutating func recordRestorationEvent(_ event: String) {
        restorationEvents.append(event)
        if restorationEvents.count > Self.maximumRestorationEvents {
            // Retain the saved position and application receipt even when
            // later layout produces more samples than the bounded history.
            let isApplication = restorationEvents[1].hasPrefix("write ") || restorationEvents[1].hasPrefix("align ")
            restorationEvents.remove(at: isApplication ? 2 : 1)
        }
    }

    mutating func recordRestorationWrite(before: CGFloat, requested: CGFloat, actual: CGFloat?, accepted: Bool) {
        guard restorationTarget != nil else { return }
        restorationEvents.removeAll { $0.hasPrefix("write ") }
        recordRestorationEvent("write before=\(before) requested=\(requested) actual=\(String(describing: actual)) accepted=\(accepted)")
    }

    mutating func recordRestorationAlignment(anchorY: CGFloat, rowY: CGFloat, before: CGFloat, immediate: CGFloat?) {
        guard restorationTarget != nil else { return }
        restorationEvents.removeAll { $0.hasPrefix("align ") }
        recordRestorationEvent("align anchor=\(anchorY) targetY=\(rowY) before=\(before) immediate=\(String(describing: immediate))")
    }

    var hasPendingRetainedRestoration: Bool { pending?.isReappearance == true }

    func retainedRestorationPosition(generation: Int) -> Position? {
        guard let pending, pending.isReappearance, pending.generation == generation else { return nil }
        return Position(id: pending.id, minY: pending.minY)
    }

    private mutating func canConsumeRestoration(
        _ measurement: Measurement,
        viewportHeight: CGFloat,
        preserve: Bool,
        pending: Pending,
        scrollGeometry: ConversationTranscriptScrollPolicy.ViewportGeometry?
    ) -> Bool {
        recordRestorationEvent("measure=\(measurement.frame) viewport=\(viewportHeight) preserve=\(preserve)")
        // Rehosting can report unavailable geometry before realizing the row.
        let frame = measurement.frame
        guard viewportHeight.isFinite, viewportHeight > 0, !frame.isInfinite,
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.size.width.isFinite, frame.size.height.isFinite,
              frame.size.width > 0, frame.size.height > 0,
              frame.maxX.isFinite, frame.maxY.isFinite,
              frame.maxY > 0, frame.minY < viewportHeight else { return false }
        if preserve, !pending.coarseScrollIssued {
            recordRestorationEvent("awaiting-coarse-command")
            return false
        }
        if preserve, !hasReachedCoarseTarget(frame, geometry: scrollGeometry) {
            recordRestorationEvent("awaiting-coarse-landing offset=\(String(describing: scrollGeometry?.contentOffsetY))")
            return false
        }
        recordRestorationEvent(preserve ? "adjust=\(measurement.frame.minY - pending.minY)" : "yielded")
        return true
    }

    private func hasReachedCoarseTarget(_ frame: CGRect, geometry: ConversationTranscriptScrollPolicy.ViewportGeometry?) -> Bool {
        guard let geometry else { return abs(frame.minY) <= Self.landingTolerance }
        guard geometry.contentOffsetY.isFinite, geometry.contentHeight.isFinite, geometry.contentHeight > 0,
              geometry.containerHeight.isFinite, geometry.containerHeight > 0,
              geometry.topInset.isFinite, geometry.bottomInset.isFinite else { return false }
        let minimum = -geometry.topInset
        let maximum = max(minimum, geometry.contentHeight - geometry.containerHeight + geometry.bottomInset)
        let target = geometry.contentOffsetY + frame.minY - geometry.topInset
        guard minimum.isFinite, maximum.isFinite, target.isFinite else { return false }
        let reachable = min(maximum, max(minimum, target))
        // A fresh callback can still describe the pre-scroll layout. Settle
        // only at the requested top alignment or its actual content boundary;
        // this also completes legitimate already-aligned/no-move commands.
        return abs(reachable - geometry.contentOffsetY) <= Self.landingTolerance
    }

    mutating func reset() {
        cancelRestoration()
        divider = nil
        initialized = false
    }
}
