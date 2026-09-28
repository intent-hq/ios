import CoreGraphics

extension ConversationTranscriptViewportAnchor {
    nonisolated struct RestorationTarget: Hashable {
        let messageID: String
    }

    enum Application {
        case offset(CGFloat)
        case retainedAlignment(target: RestorationTarget, anchorY: CGFloat, rowY: CGFloat)
    }

    static let restorationMarkerHeight: CGFloat = 1

    mutating func application(
        id: String,
        measurement: Measurement,
        geometry: ConversationTranscriptScrollPolicy.ViewportGeometry,
        preserve: Bool,
        entryGeneration: Int
    ) -> Application? {
        let retained = retainedRestorationPosition(generation: entryGeneration).flatMap { $0.id == id ? $0 : nil }
        let span = geometry.containerHeight - geometry.topInset - geometry.bottomInset - Self.restorationMarkerHeight
        let anchorY = retained.map { ($0.minY - geometry.topInset) / span }
        if let anchorY {
            // A tiny top marker has no row-height singularity, including when
            // the retained message is as tall as or larger than the viewport.
            guard span.isFinite, span > 0, anchorY.isFinite else { return nil }
        }
        guard let adjustment = record(
            id: id,
            measurement: measurement,
            viewportHeight: geometry.containerHeight,
            preserve: preserve,
            entryGeneration: entryGeneration,
            scrollGeometry: geometry
        ) else { return nil }
        if let retained, let anchorY {
            // Both realization and final placement belong to SwiftUI. A native
            // offset write can succeed and then be replaced by its pending
            // coarse scrollTo; replacing that target avoids competing owners.
            return .retainedAlignment(target: RestorationTarget(messageID: id), anchorY: anchorY, rowY: retained.minY)
        }
        return .offset(geometry.contentOffsetY + adjustment)
    }
}
