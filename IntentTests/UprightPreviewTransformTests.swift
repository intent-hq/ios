@testable import Intent
import Testing
import UIKit

/// Corrective-transform math for the upright context-menu previews
/// (CopyContextMenuOverlay): the preview target must cancel whatever flip the
/// transcript hierarchy applies to the overlay container's layer chain, and
/// must stay out of the way (identity) when the per-row un-flip already
/// cancels the scroll view's flip.
struct UprightPreviewTransformTests {
    /// The vertical flip the transcript applied before it became a
    /// natural-order ScrollView: rotation π followed by an x-mirror. Kept as
    /// the representative transform the correction must cancel.
    private var flip: CGAffineTransform {
        CGAffineTransform(rotationAngle: .pi)
            .concatenating(CGAffineTransform(scaleX: -1, y: 1))
    }

    /// A leaf layer under a chain of ancestor layers carrying `transforms`
    /// (outermost first).
    private func leafLayer(under transforms: [CGAffineTransform]) -> CALayer {
        let root = CALayer()
        var parent = root
        for transform in transforms {
            let child = CALayer()
            child.setAffineTransform(transform)
            parent.addSublayer(child)
            parent = child
        }
        let leaf = CALayer()
        parent.addSublayer(leaf)
        return leaf
    }

    private func expectEqual(
        _ actual: CGAffineTransform,
        _ expected: CGAffineTransform,
        tolerance: CGFloat = 1e-6
    ) {
        #expect(abs(actual.a - expected.a) < tolerance)
        #expect(abs(actual.b - expected.b) < tolerance)
        #expect(abs(actual.c - expected.c) < tolerance)
        #expect(abs(actual.d - expected.d) < tolerance)
        #expect(abs(actual.tx - expected.tx) < tolerance)
        #expect(abs(actual.ty - expected.ty) < tolerance)
    }

    @Test func untransformedChainNeedsNoCorrection() {
        let layer = leafLayer(under: [.identity, .identity])
        expectEqual(UprightPreviewTransform.corrective(from: layer), .identity)
    }

    @Test func doubleFlipCancelsToIdentity() {
        // The transcript hierarchy: ScrollView flipped, row flipped back.
        let layer = leafLayer(under: [flip, flip])
        expectEqual(UprightPreviewTransform.corrective(from: layer), .identity)
    }

    @Test func singleFlipIsCorrectedByVerticalFlip() {
        // Rotation π + x-mirror nets a vertical flip; its inverse is the
        // same vertical flip.
        let layer = leafLayer(under: [flip])
        expectEqual(
            UprightPreviewTransform.corrective(from: layer),
            CGAffineTransform(scaleX: 1, y: -1)
        )
    }

    @Test func flipsSplitAcrossDistantAncestorsStillAccumulate() {
        let layer = leafLayer(under: [flip, .identity, .identity, flip, .identity])
        expectEqual(UprightPreviewTransform.corrective(from: layer), .identity)
    }

    @Test func translationIsStrippedFromTheCorrection() {
        // Position comes from the preview target's center, so any
        // translation in the chain must not leak into the correction.
        let moved = flip.concatenating(CGAffineTransform(translationX: 40, y: -12))
        let layer = leafLayer(under: [moved])
        expectEqual(
            UprightPreviewTransform.corrective(from: layer),
            CGAffineTransform(scaleX: 1, y: -1)
        )
    }

    @Test func degenerateTransformFallsBackToIdentity() {
        let layer = leafLayer(under: [CGAffineTransform(scaleX: 0, y: 0)])
        expectEqual(UprightPreviewTransform.corrective(from: layer), .identity)
    }

    @Test func nearlySingularTransformIsTreatedAsDegenerate() {
        // Mid-animation an ancestor can scale through ~0; inverting such a
        // transform would produce an enormous correction for one frame.
        let layer = leafLayer(under: [CGAffineTransform(scaleX: 1e-9, y: 1e-9)])
        expectEqual(UprightPreviewTransform.corrective(from: layer), .identity)
    }
}
