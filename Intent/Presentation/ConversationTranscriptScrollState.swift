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
    /// Latest geometry-derived scrolled-away edge, recorded even while the
    /// edge is gated so it can be applied once the gate opens; nil until the
    /// first edge is observed.
    @ObservationIgnored var liveIsScrolledAway: Bool?
    var hasInitiallyScrolled = false
    var initialScrollScheduled = false
    /// True while the scheduled entry scroll waits for the finder to resolve.
    var initialScrollAwaitingScrollView = false
    var initialScrollPerformed = false
    var isScrollingToBottom = false
    /// Uptime of the last follow-to-bottom request; rate-limits streaming follows.
    var lastFollowToBottomAt: TimeInterval?
    /// True while `debounceTask` carries a forced follow, which automatic
    /// follows and scroll-away must not cancel.
    var pendingFollowIsForced = false
}