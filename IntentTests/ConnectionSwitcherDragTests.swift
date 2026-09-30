import Foundation
@testable import Intent
import Testing

struct ConnectionSwitcherDragTests {
    @Test func openingRequiresAnInwardHorizontalDragFromTheLeftEdge() {
        #expect(ConnectionSwitcherDrag.canBegin(isOpen: false, startX: 8, velocity: CGPoint(x: 100, y: 10)))
        #expect(!ConnectionSwitcherDrag.canBegin(isOpen: false, startX: 80, velocity: CGPoint(x: 100, y: 10)))
        #expect(!ConnectionSwitcherDrag.canBegin(isOpen: false, startX: 8, velocity: CGPoint(x: 10, y: 100)))
        #expect(!ConnectionSwitcherDrag.canBegin(isOpen: false, startX: 8, velocity: CGPoint(x: -100, y: 0)))
        #expect(!ConnectionSwitcherDrag.canBegin(isOpen: false, startX: -1, velocity: CGPoint(x: 100, y: 0)))
    }

    @Test func openSwitcherAcceptsHorizontalDismissalAwayFromEdgeButPreservesVerticalScrolling() {
        #expect(ConnectionSwitcherDrag.canBegin(isOpen: true, startX: 350, velocity: CGPoint(x: -100, y: 10)))
        #expect(!ConnectionSwitcherDrag.canBegin(isOpen: true, startX: 150, velocity: CGPoint(x: 10, y: -100)))
    }

    @Test func pageAlwaysLeavesAVisibleDismissalAreaAndNeverOvershoots() {
        #expect(ConnectionSwitcherDrag.revealWidth(in: 402) == 320)
        #expect(ConnectionSwitcherDrag.revealWidth(in: 320) == 238)
        #expect(ConnectionSwitcherDrag.revealWidth(in: 1_024) == 320)
        #expect(ConnectionSwitcherDrag.revealWidth(in: 50) == 0)
        #expect(ConnectionSwitcherDrag.offset(isOpen: false, translation: -50, width: 320) == 0)
        #expect(ConnectionSwitcherDrag.offset(isOpen: false, translation: 500, width: 320) == 320)
        #expect(ConnectionSwitcherDrag.offset(isOpen: true, translation: -100, width: 320) == 220)
        #expect(ConnectionSwitcherDrag.offset(isOpen: true, translation: 100, width: 320) == 320)
    }

    @Test func slowDragsSettleAtTheNearestEndpoint() {
        #expect(!ConnectionSwitcherDrag.shouldOpen(isOpen: false, translation: 80, velocity: 0, width: 320))
        #expect(ConnectionSwitcherDrag.shouldOpen(isOpen: false, translation: 200, velocity: 0, width: 320))
        #expect(ConnectionSwitcherDrag.shouldOpen(isOpen: true, translation: -80, velocity: 0, width: 320))
        #expect(!ConnectionSwitcherDrag.shouldOpen(isOpen: true, translation: -200, velocity: 0, width: 320))
    }

    @Test func flickDirectionOverridesDistanceIncludingAReversal() {
        #expect(ConnectionSwitcherDrag.shouldOpen(isOpen: false, translation: 40, velocity: 600, width: 320))
        #expect(!ConnectionSwitcherDrag.shouldOpen(isOpen: true, translation: -40, velocity: -600, width: 320))
        #expect(!ConnectionSwitcherDrag.shouldOpen(isOpen: false, translation: 200, velocity: -600, width: 320))
        #expect(!ConnectionSwitcherDrag.shouldOpen(isOpen: false, translation: 40, velocity: 600, width: 0))
    }
}
