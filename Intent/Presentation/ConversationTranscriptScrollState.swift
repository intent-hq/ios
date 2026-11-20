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
    @ObservationIgnored let trace = ConversationViewportTrace()

    typealias Lifecycle = ConversationTranscriptRecoveryLifecycle

    let momentumProxy = ScrollViewMomentumProxy()
    let rowHeightCache = ConversationTranscriptRowHeightCache()
    let disclosures = TranscriptDisclosureStore()
    @ObservationIgnored var lifecycle = Lifecycle.State() {
        didSet {
            if lifecycleOwnsViewport != lifecycle.isFollowing {
                lifecycleOwnsViewport = lifecycle.isFollowing
            }
        }
    }
    private var lifecycleOwnsViewport = false
    var isFollowing: Bool { lifecycleOwnsViewport || isScrollingToBottom }
    @ObservationIgnored var followTasks: [Lifecycle.FollowToken: Task<Void, Never>] = [:]
    @ObservationIgnored var recoveryTasks: [Lifecycle.RecoveryToken: Task<Void, Never>] = [:]
    @ObservationIgnored var pastEndRePinTask: Task<Void, Never>?
    @ObservationIgnored var containerRePinTask: Task<Void, Never>?
    @ObservationIgnored var bottomBandRePinTask: Task<Void, Never>?
    @ObservationIgnored var olderMessagesTask: Task<Void, Never>?
    @ObservationIgnored var isNearHistoryTop = false
    @ObservationIgnored var hasScrolledForHistory = false
    var userIsScrolledAway = false
    var isUserScrollPhase = false
    @ObservationIgnored var forcedFollowTakenOverByGesture = false

    enum EntryScroll: Equatable {
        case idle
        case scheduled
        case awaitingScrollView
        case settling
        case positioned
        case preserved

        var isScheduled: Bool { self != .idle }
        var isPerformed: Bool { self == .settling || self == .positioned || self == .preserved }
        var isSettled: Bool { self == .positioned || self == .preserved }
    }

    var entryScroll = EntryScroll.idle
    var hasInitiallyScrolled: Bool { entryScroll.isSettled }
    var entryViewportPreserved: Bool { entryScroll == .preserved }
    @ObservationIgnored var viewportAnchor = ConversationTranscriptViewportAnchor()
    @ObservationIgnored private var retainedViewport: ConversationTranscriptViewportAnchor.Position?
    @ObservationIgnored var pendingEntryDivider: String?
    private(set) var viewportOwnershipRevision = 0
    @ObservationIgnored private var viewportGestureActive = false
    @ObservationIgnored private(set) var initialScrollGeneration = 0
    var isScrollingToBottom = false
    @ObservationIgnored var goToEndRequested = false
    var lastFollowToBottomAt: TimeInterval?
    var lastForcedFollowOutcome: ConversationTranscriptScrollPolicy.FollowLandingTerminal?
    var forcedFollowRequestCount = 0
    var hasRequestedForcedFollow: Bool { forcedFollowRequestCount > 0 }
    var lastForcedFollowCorrections = 0
    var lastUnrealizedEndRecoveryReport: ConversationTranscriptScrollPolicy.UnrealizedEndRecoveryReport?
    var unrealizedEndRecoveryEpisodes = 0
    var unrealizedEndRecoveryCorrections = 0

    #if DEBUG
    var demoEndDerealization: DemoEndDerealization?
    @ObservationIgnored var demoEndDerealizationTriggered = false
    #endif

    @ObservationIgnored var demoRecoveryResize: DemoRecoveryResize?

    func preservePresentedViewport(distanceToBottom: CGFloat?) {
        guard !hasInitiallyScrolled else { return }
        initialScrollGeneration += 1
        entryScroll = .preserved
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

    func suspendEntryScroll() {
        initialScrollGeneration += 1
        guard !hasInitiallyScrolled else { return }
        entryScroll = .idle
    }

    var hasPendingViewportRestoration: Bool {
        retainedViewport != nil || viewportAnchor.hasPendingRetainedRestoration
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
        entryScroll = .idle
        viewportGestureActive = false
        viewportAnchor.reset()
        viewportOwnershipRevision = viewportAnchor.ownershipRevision
        forcedFollowTakenOverByGesture = false
        isScrollingToBottom = false
        goToEndRequested = false
    }

    #if DEBUG
    struct DemoEndDerealization: Equatable {
        let mode: DemoFixtures.EndDerealizationMode
        let withdrawnOffsetY: CGFloat
    }
    #endif
}
