import Foundation
import Observation

@Observable
final class ConversationTranscriptScrollState {
    let momentumProxy = ScrollViewMomentumProxy()
    var debounceTask: Task<Void, Never>?
    /// Pending re-check of a viewport that read past the end of the content.
    @ObservationIgnored var pastEndRePinTask: Task<Void, Never>?
    /// Pending settle re-check of a container re-pin deferred while the user
    /// was interacting with the scroll view.
    @ObservationIgnored var containerRePinTask: Task<Void, Never>?
    var userIsScrolledAway = false
    /// True while SwiftUI reports a user-driven scroll phase (tracking,
    /// interacting, decelerating); read next to the UIScrollView flags when a
    /// geometry edge decides whether it came from a gesture. Cleared by an
    /// explicit follow request (Go to End, the user's own message), which
    /// takes the viewport from the gesture: the phase ending that follows is
    /// then the request's, not the gesture's final sample.
    @ObservationIgnored var isUserScrollPhase = false
    /// Latched when a gesture takes over a pending forced follow; while set,
    /// content-raised forced follows are refused (see
    /// `ConversationTranscriptScrollPolicy.forcedFollowTakeoverLatch`).
    @ObservationIgnored var forcedFollowTakenOverByGesture = false
    var hasInitiallyScrolled = false
    var initialScrollScheduled = false
    /// True while the scheduled entry scroll waits for the finder to resolve.
    var initialScrollAwaitingScrollView = false
    var initialScrollPerformed = false
    var isScrollingToBottom = false
    /// Set by the Go to End tap for the `userIsScrolledAway` change handler to
    /// consume; separate from `isScrollingToBottom` so a geometry edge
    /// clearing the flag during a forced follow does not queue another one.
    @ObservationIgnored var goToEndRequested = false
    /// Uptime of the last follow-to-bottom request; rate-limits streaming follows.
    var lastFollowToBottomAt: TimeInterval?
    /// True while `debounceTask` carries a forced follow, which automatic
    /// follows must not preempt; a user gesture cancels either.
    var pendingFollowIsForced = false
    /// How the last forced follow ended (`landed`, `giveUp`, `yieldToUser`);
    /// nil while one is in flight or before the first. Read into the
    /// transcript's accessibility value under `--demo-data` so the XCUITests
    /// can tell a landed follow from one that gave up with the pin kept
    /// (#304, #305).
    var lastForcedFollowOutcome: ConversationTranscriptScrollPolicy.FollowLandingStep?
    /// Corrections (scroll again / clamp) the last forced follow has spent.
    var lastForcedFollowCorrections = 0
}