import CoreGraphics
import Foundation
import Testing
@testable import Intent

struct SplashArtViewTests {
    // MARK: - visibleSpan (strokeRoute clamping)

    @Test func segmentBeyondRevealedDistanceIsHidden() {
        // Reveal has not reached the segment yet (endDistance <= offset).
        #expect(SplashArtRenderer.visibleSpan(offset: 10, length: 5, endDistance: 9) == nil)
        #expect(SplashArtRenderer.visibleSpan(offset: 10, length: 5, endDistance: 10) == nil)
        // Nothing revealed at all.
        #expect(SplashArtRenderer.visibleSpan(offset: 0, length: 5, endDistance: 0) == nil)
    }

    @Test func partiallyRevealedSegmentClampsEnd() {
        let span = SplashArtRenderer.visibleSpan(offset: 10, length: 5, endDistance: 12)
        #expect(span != nil)
        #expect(span?.start == 0)
        #expect(span?.end == 0.4)
    }

    @Test func fullyRevealedSegmentSpansWholeArc() {
        // Exactly at the segment's far edge and beyond it.
        let atEdge = SplashArtRenderer.visibleSpan(offset: 10, length: 5, endDistance: 15)
        #expect(atEdge?.start == 0 && atEdge?.end == 1)
        let beyond = SplashArtRenderer.visibleSpan(offset: 10, length: 5, endDistance: 100)
        #expect(beyond?.start == 0 && beyond?.end == 1)
    }

    @Test func firstSegmentRevealsFromItsStart() {
        // offset 0: the route's first segment starts revealing immediately.
        let span = SplashArtRenderer.visibleSpan(offset: 0, length: 8, endDistance: 2)
        #expect(span?.start == 0)
        #expect(span?.end == 0.25)
    }

    // MARK: - Touch reach parity with app.html pointer handlers

    @Test func initialTouchUsesPointerdownReach() {
        #expect(SplashArtRenderer.reachFactor(isInitialTouch: true)
            == SplashArtModel.tapReachFactor)
        #expect(SplashArtModel.tapReachFactor == 1.8)
    }

    @Test func dragMovementUsesPointermoveReach() {
        #expect(SplashArtRenderer.reachFactor(isInitialTouch: false)
            == SplashArtModel.hoverReachFactor)
        #expect(SplashArtModel.hoverReachFactor == 0.72)
    }

    // MARK: - Renderer model lifecycle

    @Test func flipNearBeforeFirstDrawIsSafe() {
        let renderer = SplashArtRenderer()
        // No model yet (nothing drawn): must not crash or build state.
        renderer.flipNear(location: CGPoint(x: 10, y: 10), reachFactor: 1.8, now: 0)
        #expect(renderer.model == nil)
    }
}
