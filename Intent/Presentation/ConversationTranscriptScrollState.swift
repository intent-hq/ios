import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class ConversationTranscriptRowHeightCache {
    private struct Content: Equatable {
        let message: ConversationMessage
        let hydratingBlockIds: Set<String>
    }

    private struct Entry: Equatable {
        let content: Content
        let height: CGFloat
    }

    private struct PendingMeasurement {
        let token: UUID
        let task: Task<Void, Never>
    }

    private static let widthTolerance: CGFloat = 0.5

    private let settleDelay: Duration
    private var entries: [String: Entry] = [:]
    @ObservationIgnored private var cacheGenerationWidth: CGFloat?
    @ObservationIgnored private var currentMessageIDs: Set<String> = []
    @ObservationIgnored private var hasEstablishedCurrentMessages = false
    @ObservationIgnored private var pendingMeasurements: [String: PendingMeasurement] = [:]

    init(settleDelay: Duration = .milliseconds(Constants.Conversation.Transcript.rowHeightSettleMilliseconds)) {
        self.settleDelay = settleDelay
    }

    func height(for message: ConversationMessage, hydratingBlockIds: Set<String>) -> CGFloat? {
        guard !message.isStreaming,
              let entry = entries[message.id],
              entry.content == Content(message: message, hydratingBlockIds: hydratingBlockIds)
        else { return nil }
        return entry.height
    }

    @discardableResult
    func record(
        height: CGFloat,
        for message: ConversationMessage,
        hydratingBlockIds: Set<String>
    ) -> Bool {
        guard !hasEstablishedCurrentMessages || currentMessageIDs.contains(message.id) else {
            invalidate(messageId: message.id)
            return false
        }
        guard !message.isStreaming, height.isFinite, height > 0 else {
            invalidate(messageId: message.id)
            return false
        }

        let content = Content(message: message, hydratingBlockIds: hydratingBlockIds)
        pendingMeasurements.removeValue(forKey: message.id)?.task.cancel()
        if entries[message.id] == Entry(content: content, height: height) { return true }

        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: settleDelay)
            guard !Task.isCancelled else { return }
            finishMeasurement(messageId: message.id, token: token, content: content, height: height)
        }
        pendingMeasurements[message.id] = PendingMeasurement(token: token, task: task)
        return true
    }

    @discardableResult
    func record(
        height: CGFloat,
        for message: ConversationMessage,
        hydratingBlockIds: Set<String>,
        retainingMessagesWithIDs messageIDs: Set<String>
    ) -> Bool {
        retainMessages(withIDs: messageIDs)
        return record(height: height, for: message, hydratingBlockIds: hydratingBlockIds)
    }

    func invalidate(messageId: String) {
        pendingMeasurements.removeValue(forKey: messageId)?.task.cancel()
        entries.removeValue(forKey: messageId)
    }

    func retainMessages(withIDs messageIDs: Set<String>) {
        currentMessageIDs = messageIDs
        hasEstablishedCurrentMessages = true
        let retiredMessageIDs = Set(entries.keys)
            .union(Set(pendingMeasurements.keys))
            .subtracting(messageIDs)
        for messageID in retiredMessageIDs {
            invalidate(messageId: messageID)
        }
    }

    func invalidateAll() {
        pendingMeasurements.values.forEach { $0.task.cancel() }
        pendingMeasurements.removeAll()
        entries.removeAll()
    }

    func updateLayoutWidth(_ width: CGFloat) {
        guard width.isFinite, width > 0 else { return }
        guard let cacheGenerationWidth else {
            self.cacheGenerationWidth = width
            return
        }
        guard abs(cacheGenerationWidth - width) > Self.widthTolerance else { return }
        self.cacheGenerationWidth = width
        invalidateAll()
    }

    private func finishMeasurement(
        messageId: String,
        token: UUID,
        content: Content,
        height: CGFloat
    ) {
        guard !hasEstablishedCurrentMessages || currentMessageIDs.contains(messageId),
              pendingMeasurements[messageId]?.token == token
        else { return }
        pendingMeasurements.removeValue(forKey: messageId)
        entries[messageId] = Entry(content: content, height: height)
    }
}

@Observable
final class ConversationTranscriptScrollState {
    typealias Lifecycle = ConversationTranscriptRecoveryLifecycle

    let momentumProxy = ScrollViewMomentumProxy()
    let rowHeightCache = ConversationTranscriptRowHeightCache()
    /// Who owns the viewport (a follow from its request to its terminal, an
    /// unrealized-end correction from its first scroll to its terminal), the
    /// recovery armed without owning, a give-up transferred to the owning
    /// follow, and whether the end row (the `scroll-bottom` marker) is
    /// realized by the lazy stack. Written only through
    /// `Lifecycle.transition`; the view executes the effects.
    @ObservationIgnored var lifecycle = Lifecycle.State() {
        didSet {
            if lifecycleOwnsViewport != lifecycle.isFollowing {
                lifecycleOwnsViewport = lifecycle.isFollowing
            }
        }
    }
    /// Publish ownership changes, including an automatic follow draining after
    /// recovery. The rest of the reducer's polling state need not redraw the view.
    private var lifecycleOwnsViewport = false
    var isFollowing: Bool { lifecycleOwnsViewport || isScrollingToBottom }
    /// The pending follow's debounce and landing loop, keyed by the token
    /// the lifecycle minted for it.
    @ObservationIgnored var followTasks: [Lifecycle.FollowToken: Task<Void, Never>] = [:]
    /// The recovery loop verifying that a following viewport rests on
    /// realized rows (#338), keyed by the token the lifecycle minted for it.
    @ObservationIgnored var recoveryTasks: [Lifecycle.RecoveryToken: Task<Void, Never>] = [:]
    /// Pending re-check of a viewport that read past the end of the content.
    @ObservationIgnored var pastEndRePinTask: Task<Void, Never>?
    /// Pending settle re-check of a container re-pin deferred while the user
    /// was interacting with the scroll view.
    @ObservationIgnored var containerRePinTask: Task<Void, Never>?
    /// Pending settle re-check of a pinned viewport that a geometry edge (or
    /// streaming ending) read within the at-bottom band (#346).
    @ObservationIgnored var bottomBandRePinTask: Task<Void, Never>?
    @ObservationIgnored var olderMessagesTask: Task<Void, Never>?
    @ObservationIgnored var isNearHistoryTop = false
    @ObservationIgnored var hasScrolledForHistory = false
    var userIsScrolledAway = false
    /// True while SwiftUI reports a user-driven scroll phase (tracking,
    /// interacting, decelerating); read next to the UIScrollView flags when a
    /// geometry edge decides whether it came from a gesture. Cleared by an
    /// explicit follow request (Go to End, the user's own message), which
    /// takes the viewport from the gesture: the phase ending that follows is
    /// then the request's, not the gesture's final sample.
    var isUserScrollPhase = false
    /// Latched when a gesture takes over a pending forced follow; while set,
    /// content-raised forced follows are refused (see
    /// `ConversationTranscriptScrollPolicy.forcedFollowTakeoverLatch`).
    @ObservationIgnored var forcedFollowTakenOverByGesture = false
    var hasInitiallyScrolled = false
    var initialScrollScheduled = false
    /// True while the scheduled entry scroll waits for the finder to resolve.
    var initialScrollAwaitingScrollView = false
    var initialScrollPerformed = false
    var presentedBeforeEntryMetadata = false
    private(set) var entryViewportPreserved = false
    @ObservationIgnored var viewportAnchor = ConversationTranscriptViewportAnchor()
    @ObservationIgnored private var retainedViewport: ConversationTranscriptViewportAnchor.Position?
    @ObservationIgnored var pendingEntryDivider: String?
    /// Publishes ownership changes without observing every row measurement.
    private(set) var viewportOwnershipRevision = 0
    @ObservationIgnored private var viewportGestureActive = false
    /// Invalidates delayed entry-scroll callbacks when an emptied transcript
    /// re-arms entry scrolling for the next snapshot.
    @ObservationIgnored private(set) var initialScrollGeneration = 0
    /// Mirrors a forced follow owning the viewport (`lifecycle.owner`): raised
    /// by the Go to End tap ahead of its request and by a forced follow
    /// starting, cleared when that follow drains or is cancelled.
    var isScrollingToBottom = false
    /// Set by the Go to End tap for the `userIsScrolledAway` change handler to
    /// consume; separate from `isScrollingToBottom` so a geometry edge
    /// clearing the flag during a forced follow does not queue another one.
    @ObservationIgnored var goToEndRequested = false
    /// Uptime of the last follow-to-bottom request; rate-limits streaming follows.
    var lastFollowToBottomAt: TimeInterval?
    /// How the last forced follow ended (`landed`, `giveUp`, `yieldToUser`);
    /// nil while one is in flight or before the first. Read into the
    /// transcript's accessibility value under `--demo-data` so the XCUITests
    /// can tell a landed follow from one that gave up with the pin kept
    /// (#304, #305).
    var lastForcedFollowOutcome: ConversationTranscriptScrollPolicy.FollowLandingTerminal?
    var forcedFollowRequestCount = 0
    var hasRequestedForcedFollow: Bool { forcedFollowRequestCount > 0 }
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
    /// Content-free receipt for the opt-in footer/recovery overlap control.
    @ObservationIgnored var demoRecoveryResize: DemoRecoveryResize?

    /// Visible content and user gestures take priority over late entry metadata.
    /// Invalidate scheduled entry callbacks, but retain the authoritative divider.
    func preservePresentedViewport(distanceToBottom: CGFloat?) {
        guard !hasInitiallyScrolled else { return }
        initialScrollGeneration += 1
        initialScrollScheduled = true
        initialScrollAwaitingScrollView = false
        initialScrollPerformed = true
        hasInitiallyScrolled = true
        entryViewportPreserved = true
        userIsScrolledAway = NewMessagesDivider.followDisabledAfterEntryScroll(distanceToBottom: distanceToBottom)
    }

    func observeViewportGesture(isInteracting: Bool) {
        guard viewportGestureActive != isInteracting else { return }
        viewportGestureActive = isInteracting
        if isInteracting {
            retainedViewport = nil
            pendingEntryDivider = nil
            viewportAnchor.cancelRestoration()
            viewportOwnershipRevision = viewportAnchor.ownershipRevision
        }
    }

    /// An explicit follow or disappearance retires even callbacks that have
    /// been captured but have not yet created a pending adjustment.
    func retireViewportRestoration() {
        retainedViewport = nil
        pendingEntryDivider = nil
        viewportGestureActive = false
        viewportAnchor.cancelRestoration()
        viewportOwnershipRevision = viewportAnchor.ownershipRevision
    }

    func suspendViewport() {
        let position = hasInitiallyScrolled ? viewportAnchor.visiblePosition : nil
        retireViewportRestoration()
        retainedViewport = position
    }

    func entryDividerAdjustment(_ measurement: ConversationTranscriptViewportAnchor.Measurement, viewportHeight: CGFloat) -> CGFloat? {
        guard pendingEntryDivider != nil, pendingEntryDivider == measurement.divider,
              measurement.generation == initialScrollGeneration,
              measurement.ownershipRevision == viewportOwnershipRevision,
              measurement.frame.height > 0, measurement.frame.minY >= 0,
              measurement.frame.maxY <= viewportHeight else { return nil }
        pendingEntryDivider = nil
        return measurement.frame.minY
    }

    func resumeViewportTarget() -> String? {
        guard let position = retainedViewport else { return nil }
        retainedViewport = nil
        // The rehosted view must measure afresh; a callback captured while
        // covered cannot consume this new restoration.
        viewportAnchor.cancelRestoration()
        viewportOwnershipRevision = viewportAnchor.ownershipRevision
        viewportAnchor.restore(position, generation: initialScrollGeneration)
        return position.id
    }

    func retainedViewportScrollIssued(target: String, generation: Int, ownershipRevision: Int) {
        guard generation == initialScrollGeneration else { return }
        viewportAnchor.retainedScrollIssued(target: target, generation: generation, ownershipRevision: ownershipRevision)
        viewportOwnershipRevision = viewportAnchor.ownershipRevision
    }

    func retainViewportMessages(withIDs messageIDs: Set<String>) {
        if let retainedViewport, !messageIDs.contains(retainedViewport.id) { self.retainedViewport = nil }
        viewportAnchor.retainMessages(withIDs: messageIDs)
        viewportOwnershipRevision = viewportAnchor.ownershipRevision
    }

    func rearmAfterTranscriptEmptied() {
        retainedViewport = nil
        initialScrollGeneration += 1
        pendingEntryDivider = nil
        userIsScrolledAway = false
        hasInitiallyScrolled = false
        initialScrollScheduled = false
        initialScrollAwaitingScrollView = false
        initialScrollPerformed = false
        presentedBeforeEntryMetadata = false
        entryViewportPreserved = false
        viewportGestureActive = false
        viewportAnchor.reset()
        viewportOwnershipRevision = viewportAnchor.ownershipRevision
        forcedFollowTakenOverByGesture = false
        isScrollingToBottom = false
        goToEndRequested = false
    }

    struct DemoEndDerealization: Equatable {
        let mode: DemoFixtures.EndDerealizationMode
        let withdrawnOffsetY: CGFloat
    }
}
