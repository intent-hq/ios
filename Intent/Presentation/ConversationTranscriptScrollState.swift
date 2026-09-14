import Foundation
import Observation

@Observable
final class ConversationTranscriptScrollState {
    let momentumProxy = ScrollViewMomentumProxy()
    var debounceTask: Task<Void, Never>?
    var userIsScrolledAway = false
    /// Latest geometry-derived scrolled-away edge, recorded even while the
    /// edge is gated so it can be applied once the gate opens.
    @ObservationIgnored var liveIsScrolledAway = false
    var hasInitiallyScrolled = false
    var initialScrollScheduled = false
    var isScrollingToBottom = false
    /// Uptime of the last follow-to-bottom request; rate-limits streaming follows.
    var lastFollowToBottomAt: TimeInterval?
    /// True while `debounceTask` carries a forced follow, which automatic
    /// follows and scroll-away must not cancel.
    var pendingFollowIsForced = false
}