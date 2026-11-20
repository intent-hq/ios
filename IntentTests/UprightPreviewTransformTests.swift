@testable import Intent
import Testing
import UIKit

struct UprightPreviewTransformTests {
    private var flip: CGAffineTransform {
        CGAffineTransform(rotationAngle: .pi)
            .concatenating(CGAffineTransform(scaleX: -1, y: 1))
    }

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
        let layer = leafLayer(under: [flip, flip])
        expectEqual(UprightPreviewTransform.corrective(from: layer), .identity)
    }

    @Test func singleFlipIsCorrectedByVerticalFlip() {
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
        let layer = leafLayer(under: [CGAffineTransform(scaleX: 1e-9, y: 1e-9)])
        expectEqual(UprightPreviewTransform.corrective(from: layer), .identity)
    }
}
