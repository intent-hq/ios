import Foundation
@testable import Intent
import Testing
import UIKit

extension ConversationTranscriptScrollPolicyTests {
    @Test(arguments: ["tracking", "dragging", "decelerating"]) @MainActor
    func gestureAccessibilityReadsUIKitAfterTheLastSwiftUIRender(flag: String) {
        let state = ConversationTranscriptScrollState()
        let scrollView = TranscriptGestureTestScrollView()
        state.momentumProxy.scrollView = scrollView
        let probe = TranscriptGestureAccessibilityView()
        probe.scrollState = state
        state.isUserScrollPhase = true
        scrollView.activeFlag = flag
        let renderedWhileActive = probe.accessibilityValue
        #expect(renderedWhileActive?.hasPrefix("phase=gesture ") == true)

        // SwiftUI can publish idle while UIKit still reports deceleration.
        state.isUserScrollPhase = false
        #expect(probe.accessibilityValue?.hasPrefix("phase=gesture ") == true)
        // No view update, layout or observable state write follows this edge.
        scrollView.activeFlag = nil
        #expect(probe.accessibilityValue?.hasPrefix("phase=idle ") == true)
        #expect(renderedWhileActive?.hasPrefix("phase=gesture ") == true)
    }

    @Test @MainActor func gestureAccessibilityWaitsForSwiftUIWhenUIKitFinishesFirst() {
        let state = ConversationTranscriptScrollState()
        let scrollView = TranscriptGestureTestScrollView()
        state.momentumProxy.scrollView = scrollView
        let probe = TranscriptGestureAccessibilityView()
        probe.scrollState = state
        state.isUserScrollPhase = true
        scrollView.activeFlag = "decelerating"
        scrollView.activeFlag = nil
        #expect(probe.accessibilityValue?.hasPrefix("phase=gesture ") == true)
        state.isUserScrollPhase = false
        #expect(probe.accessibilityValue?.hasPrefix("phase=idle ") == true)
    }

    @Test @MainActor func gestureAccessibilityCannotReportIdleWithoutItsLiveScrollView() {
        let state = ConversationTranscriptScrollState()
        let probe = TranscriptGestureAccessibilityView()
        #expect(probe.accessibilityValue == "phase=unresolved")
        probe.scrollState = state
        #expect(probe.accessibilityValue == "phase=unresolved")
        var scrollView: TranscriptGestureTestScrollView? = TranscriptGestureTestScrollView()
        state.momentumProxy.scrollView = scrollView
        #expect(probe.accessibilityValue?.hasPrefix("phase=idle ") == true)
        scrollView = nil
        #expect(state.momentumProxy.scrollView == nil)
        #expect(probe.accessibilityValue == "phase=unresolved")
    }

    @Test @MainActor func gestureAccessibilityRebindingReadsOnlyTheCurrentWindow() {
        let first = ConversationTranscriptScrollState()
        let second = ConversationTranscriptScrollState()
        let firstScroll = TranscriptGestureTestScrollView()
        let secondScroll = TranscriptGestureTestScrollView()
        first.momentumProxy.scrollView = firstScroll
        second.momentumProxy.scrollView = secondScroll
        firstScroll.activeFlag = "dragging"
        let probe = TranscriptGestureAccessibilityView()
        probe.scrollState = first
        #expect(probe.accessibilityValue?.hasPrefix("phase=gesture ") == true)
        probe.scrollState = second
        #expect(probe.accessibilityValue?.hasPrefix("phase=idle ") == true)
        first.isUserScrollPhase = true
        #expect(probe.accessibilityValue?.hasPrefix("phase=idle ") == true)
        secondScroll.activeFlag = "tracking"
        #expect(probe.accessibilityValue?.hasPrefix("phase=gesture ") == true)
        probe.scrollState = nil
        #expect(probe.accessibilityValue == "phase=unresolved")
    }
}

@MainActor
private final class TranscriptGestureTestScrollView: UIScrollView {
    var activeFlag: String?
    override var isTracking: Bool { activeFlag == "tracking" }
    override var isDragging: Bool { activeFlag == "dragging" }
    override var isDecelerating: Bool { activeFlag == "decelerating" }
}
