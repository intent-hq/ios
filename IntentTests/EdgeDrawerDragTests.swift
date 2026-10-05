import Foundation
@testable import Intent
import Testing

struct EdgeDrawerDragTests {
    @Test func openingRequiresAnInwardHorizontalDragFromTheLeftEdge() {
        #expect(EdgeDrawerDrag.canBegin(isOpen: false, startX: 8, velocity: CGPoint(x: 100, y: 10)))
        #expect(!EdgeDrawerDrag.canBegin(isOpen: false, startX: 80, velocity: CGPoint(x: 100, y: 10)))
        #expect(!EdgeDrawerDrag.canBegin(isOpen: false, startX: 8, velocity: CGPoint(x: 10, y: 100)))
        #expect(!EdgeDrawerDrag.canBegin(isOpen: false, startX: 8, velocity: CGPoint(x: -100, y: 0)))
        #expect(!EdgeDrawerDrag.canBegin(isOpen: false, startX: -1, velocity: CGPoint(x: 100, y: 0)))
    }

    @Test func openSwitcherAcceptsHorizontalDismissalAwayFromEdgeButPreservesVerticalScrolling() {
        #expect(EdgeDrawerDrag.canBegin(isOpen: true, startX: 350, velocity: CGPoint(x: -100, y: 10)))
        #expect(!EdgeDrawerDrag.canBegin(isOpen: true, startX: 150, velocity: CGPoint(x: 10, y: -100)))
    }

    @Test func pageAlwaysLeavesAVisibleDismissalAreaAndNeverOvershoots() {
        #expect(EdgeDrawerDrag.revealWidth(in: 402) == 320)
        #expect(EdgeDrawerDrag.revealWidth(in: 320) == 238)
        #expect(EdgeDrawerDrag.revealWidth(in: 1024) == 320)
        #expect(EdgeDrawerDrag.revealWidth(in: 50) == 0)
        #expect(EdgeDrawerDrag.offset(isOpen: false, translation: -50, width: 320) == 0)
        #expect(EdgeDrawerDrag.offset(isOpen: false, translation: 500, width: 320) == 320)
        #expect(EdgeDrawerDrag.offset(isOpen: true, translation: -100, width: 320) == 220)
        #expect(EdgeDrawerDrag.offset(isOpen: true, translation: 100, width: 320) == 320)
    }

    @Test func slowDragsSettleAtTheNearestEndpoint() {
        #expect(!EdgeDrawerDrag.shouldOpen(isOpen: false, translation: 80, velocity: 0, width: 320))
        #expect(EdgeDrawerDrag.shouldOpen(isOpen: false, translation: 200, velocity: 0, width: 320))
        #expect(EdgeDrawerDrag.shouldOpen(isOpen: true, translation: -80, velocity: 0, width: 320))
        #expect(!EdgeDrawerDrag.shouldOpen(isOpen: true, translation: -200, velocity: 0, width: 320))
    }

    @Test func flickDirectionOverridesDistanceIncludingAReversal() {
        #expect(EdgeDrawerDrag.shouldOpen(isOpen: false, translation: 40, velocity: 600, width: 320))
        #expect(!EdgeDrawerDrag.shouldOpen(isOpen: true, translation: -40, velocity: -600, width: 320))
        #expect(!EdgeDrawerDrag.shouldOpen(isOpen: false, translation: 200, velocity: -600, width: 320))
        #expect(!EdgeDrawerDrag.shouldOpen(isOpen: false, translation: 40, velocity: 600, width: 0))
    }

    @Test func rightDrawerOpensFromTheRightEdgeWithALeftwardDrag() {
        let width: CGFloat = 402
        let startX = EdgeDrawerDrag.distanceFromEdge(395, width: width, side: .right)
        let leftward = EdgeDrawerDrag.towardOpening(-100, side: .right)
        #expect(EdgeDrawerDrag.canBegin(isOpen: false, startX: startX, velocity: CGPoint(x: leftward, y: 10)))
        let rightward = EdgeDrawerDrag.towardOpening(100, side: .right)
        #expect(!EdgeDrawerDrag.canBegin(isOpen: false, startX: startX, velocity: CGPoint(x: rightward, y: 10)))
        let leftEdge = EdgeDrawerDrag.distanceFromEdge(8, width: width, side: .right)
        #expect(!EdgeDrawerDrag.canBegin(isOpen: false, startX: leftEdge, velocity: CGPoint(x: leftward, y: 10)))
    }
}
