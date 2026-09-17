import CoreGraphics
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
    /// Pending verification that a following viewport rests on realized
    /// rows, armed when the end row derealizes (#338).
    @ObservationIgnored var unrealizedEndRecoveryTask: Task<Void, Never>?
    /// True while the transcript's end row (the `scroll-bottom` marker) is
    /// realized by the lazy stack; a following viewport at rest at the
    /// bottom with this false is blank (see
    /// `ConversationTranscriptScrollPolicy.unrealizedEndRecoveryStep`).
    @ObservationIgnored var isEndRealized = false
    /// True from an unrealized-end correction being issued until the
    /// recovery resolves; counts as a follow in flight for the other paths.
    @ObservationIgnored var isRecoveringUnrealizedEnd = false
    /// Set when the recovery gave up while a follow was in flight; that
    /// follow's drain (or its cancellation) resolves it (see
    /// `ConversationTranscriptScrollPolicy.shouldShowGoToEndAfterFollow`).
    @ObservationIgnored var unrealizedEndGiveUpDeferredToFollow = false
    /// Pending settle re-check of a pinned viewport that a geometry edge (or
    /// streaming ending) read within the at-bottom band (#346).
    @ObservationIgnored var bottomBandRePinTask: Task<Void, Never>?
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
    /// How the last unrealized-end recovery episode ended (#338): recorded
    /// on every terminal path — resolved, given up, yielded or cancelled —
    /// with the end row's realization at that moment; nil while an episode
    /// is in flight, or before the first. Demo-only diagnostics like the
    /// forced follow's.
    var lastUnrealizedEndRecoveryReport: ConversationTranscriptScrollPolicy.UnrealizedEndRecoveryReport?
    /// Episodes armed on this transcript so far.
    var unrealizedEndRecoveryEpisodes = 0
    /// Corrections the in-flight (or, once it ended, the last) episode has
    /// spent, published as each is issued so a cancellation records them.
    var unrealizedEndRecoveryCorrections = 0
    /// Demo-only (`--demo-end-derealization-trigger-file`): while set, the
    /// end row is withdrawn from the lazy stack so its real `onDisappear`
    /// armed the recovery, with the live offset at withdrawal the restore
    /// is judged against (see `DemoFixtures.shouldRestoreDerealizedEnd`).
    /// Never set outside `--demo-data`.
    var demoEndDerealization: DemoEndDerealization?
    /// Set once the trigger has fired so a re-run of the poll does not
    /// withdraw the row again.
    @ObservationIgnored var demoEndDerealizationTriggered = false

    struct DemoEndDerealization: Equatable {
        let mode: DemoFixtures.EndDerealizationMode
        let withdrawnOffsetY: CGFloat
    }
}
