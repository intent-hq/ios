import Foundation
@testable import Intent
import Testing
import UIKit

struct ConversationTranscriptScrollPolicyTests {
    private typealias Step = ConversationTranscriptScrollPolicy.InitialScrollStep

    private func initialStep(
        alreadyPerformed: Bool = false,
        scrollViewResolved: Bool = false,
        scrollViewWaitElapsed: Bool = false
    ) -> Step {
        ConversationTranscriptScrollPolicy.initialScrollStep(
            alreadyPerformed: alreadyPerformed,
            scrollViewResolved: scrollViewResolved,
            scrollViewWaitElapsed: scrollViewWaitElapsed
        )
    }

    @Test func entryScrollWaitsForFinderWhenTimerBeatsHosting() {
        #expect(initialStep(scrollViewResolved: false) == .waitForScrollView)
        #expect(initialStep(scrollViewResolved: true) == .perform)
    }

    @Test func entryScrollFallsBackAfterBoundedWait() {
        #expect(initialStep(scrollViewResolved: false, scrollViewWaitElapsed: true) == .perform)
    }

    @Test func entryScrollPerformsAtMostOnce() {
        #expect(initialStep(alreadyPerformed: true, scrollViewResolved: true) == .skip)
        #expect(initialStep(alreadyPerformed: true, scrollViewWaitElapsed: true) == .skip)
        #expect(initialStep(alreadyPerformed: true) == .skip)
    }

    @Test func emptyReplacementRearmsEntryScrollForTheNextSnapshot() {
        let state = ConversationTranscriptScrollState()
        state.userIsScrolledAway = true
        state.entryScroll = .positioned
        state.isScrollingToBottom = true
        let generation = state.initialScrollGeneration

        #expect(ConversationTranscriptScrollPolicy.messageCountChangeDecision(
            from: 12,
            to: 0,
            hasInitiallyScrolled: true
        ) == .rearmEntryScroll)
        state.rearmAfterTranscriptEmptied()
        #expect(!state.userIsScrolledAway)
        #expect(state.entryScroll == .idle)
        #expect(!state.isScrollingToBottom)
        #expect(state.initialScrollGeneration == generation + 1)
        #expect(ConversationTranscriptScrollPolicy.messageCountChangeDecision(
            from: 0,
            to: 8,
            hasInitiallyScrolled: state.hasInitiallyScrolled
        ) == .runEntryScroll)
    }

    @Test func emptyReplacementInvalidatesPendingDividerProbe() {
        let state = ConversationTranscriptScrollState()
        let staleGeneration = state.initialScrollGeneration

        state.rearmAfterTranscriptEmptied()
        state.applyDividerProbe(distanceToBottom: 100, generation: staleGeneration)

        #expect(!state.userIsScrolledAway)
    }

    @Test func matchingGenerationDividerProbeMarksScrolledAway() {
        let state = ConversationTranscriptScrollState()

        state.applyDividerProbe(
            distanceToBottom: 100,
            generation: state.initialScrollGeneration
        )

        #expect(state.userIsScrolledAway)
    }

    @Test func shorterReplacementRechecksForPastEndRePin() {
        #expect(ConversationTranscriptScrollPolicy.messageCountChangeDecision(
            from: 40,
            to: 10,
            hasInitiallyScrolled: true
        ) == .rePinIfPastEnd)
    }

    @Test func entryScrollDelaysAreOrdered() {
        #expect(Constants.Conversation.Transcript.initialScrollHostingTimeout
            > Constants.Conversation.Transcript.initialScrollDelay)
        #expect(Constants.Conversation.Transcript.dividerProbeDelay
            < Constants.Conversation.Transcript.initialScrollSettleDelay)
    }

    @Test func tracksAwayStateAcrossBottomThreshold() {
        #expect(!ConversationTranscriptScrollPolicy.isScrolledAway(distanceToBottom: -20))
        #expect(!ConversationTranscriptScrollPolicy.isScrolledAway(distanceToBottom: 50))
        #expect(ConversationTranscriptScrollPolicy.isScrolledAway(distanceToBottom: 51))
    }

    @Test func distanceToBottomIsZeroAtRestAtBottom() {
        #expect(ConversationTranscriptScrollPolicy.distanceToBottom(
            contentHeight: 1000,
            contentOffsetY: 300,
            containerHeight: 700
        ) == 0)
        #expect(ConversationTranscriptScrollPolicy.distanceToBottom(
            contentHeight: 1000,
            contentOffsetY: 334,
            containerHeight: 700,
            bottomInset: 34
        ) == 0)
    }

    @Test func distanceToBottomIsZeroAtRestUnderTopInsetWhenMeasuredWithVisibleRect() {
        #expect(ConversationTranscriptScrollPolicy.distanceToBottom(
            contentHeight: 1968,
            contentOffsetY: 1188,
            containerHeight: 780
        ) == 0)
        #expect(ConversationTranscriptScrollPolicy.distanceToBottom(
            contentHeight: 1968,
            contentOffsetY: 1188,
            containerHeight: 664
        ) == 116)
    }

    @Test func distanceToBottomGrowsAsViewportScrollsUp() {
        #expect(ConversationTranscriptScrollPolicy.distanceToBottom(
            contentHeight: 1000,
            contentOffsetY: 100,
            containerHeight: 700
        ) == 200)
    }

    func transition(
        current: Bool,
        distanceToBottom: CGFloat,
        isInteracting: Bool,
        isEndRealized: Bool = true
    ) -> Bool {
        ConversationTranscriptScrollPolicy.scrolledAwayTransition(
            current: current,
            geometryAway: ConversationTranscriptScrollPolicy.isScrolledAway(
                distanceToBottom: distanceToBottom,
                atBottomThreshold: 50
            ),
            isInteracting: isInteracting,
            isEndRealized: isEndRealized
        )
    }

    @Test func contentGrowthWhilePinnedWithoutGestureKeepsThePin() {
        #expect(!transition(current: false, distanceToBottom: 51, isInteracting: false))
        #expect(!transition(current: false, distanceToBottom: 379, isInteracting: false))
        #expect(!transition(current: false, distanceToBottom: 0, isInteracting: false))
    }

    @Test func draggingUpBeyondThresholdScrollsAway() {
        #expect(transition(current: false, distanceToBottom: 51, isInteracting: true))
        #expect(!transition(current: false, distanceToBottom: 50, isInteracting: true))
    }

    @Test func decelerationAfterFlingDecidesByWhereItRests() {
        #expect(transition(current: false, distanceToBottom: 200, isInteracting: true))
        #expect(!transition(current: false, distanceToBottom: 20, isInteracting: true))
    }

    @Test func returningWithinThresholdRePinsWithOrWithoutGesture() {
        #expect(!transition(current: true, distanceToBottom: 50, isInteracting: true))
        #expect(!transition(current: true, distanceToBottom: 0, isInteracting: false))
        #expect(!transition(current: true, distanceToBottom: -30, isInteracting: false))
    }

    @Test func scrolledAwayStaysAwayWhileContentGrows() {
        #expect(transition(current: true, distanceToBottom: 400, isInteracting: false))
        #expect(transition(current: true, distanceToBottom: 400, isInteracting: true))
    }

    @Test func bouncePastEndWhilePinnedStaysPinned() {
        #expect(!transition(current: false, distanceToBottom: -60, isInteracting: true))
        #expect(!transition(current: false, distanceToBottom: -60, isInteracting: false))
    }

    func rePinAfterGrowth(
        geometryAway: Bool = true,
        isInteracting: Bool = false,
        isFollowing: Bool = false,
        hasInitiallyScrolled: Bool = true,
        userIsScrolledAway: Bool = false
    ) -> Bool {
        ConversationTranscriptScrollPolicy.shouldRePinAfterContentGrowth(
            geometryAway: geometryAway,
            isInteracting: isInteracting,
            isFollowing: isFollowing,
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway
        )
    }

    @Test func contentGrowthUnderPinnedViewportRePins() {
        #expect(rePinAfterGrowth())
        #expect(!rePinAfterGrowth(geometryAway: false))
    }

    @Test func contentGrowthRePinYieldsToGesturesFollowsAndTheEntryDecision() {
        #expect(!rePinAfterGrowth(isInteracting: true))
        #expect(!rePinAfterGrowth(isFollowing: true))
        #expect(!rePinAfterGrowth(hasInitiallyScrolled: false))
        #expect(!rePinAfterGrowth(userIsScrolledAway: true))
    }

    @Test func distanceToBottomIsNegativeForShortContentAndOverscroll() {
        #expect(ConversationTranscriptScrollPolicy.distanceToBottom(
            contentHeight: 400,
            contentOffsetY: 0,
            containerHeight: 700
        ) == -300)
        #expect(ConversationTranscriptScrollPolicy.distanceToBottom(
            contentHeight: 1000,
            contentOffsetY: 360,
            containerHeight: 700
        ) == -60)
    }

    private typealias RePinDecision = ConversationTranscriptScrollPolicy.RePinDecision

    private func rePinDecision(
        offsetY: CGFloat,
        isInteracting: Bool = false,
        contentHeight: CGFloat = 1000,
        containerHeight: CGFloat = 700,
        topInset: CGFloat = 0,
        bottomInset: CGFloat = 0
    ) -> RePinDecision {
        ConversationTranscriptScrollPolicy.rePinDecision(
            contentOffsetY: offsetY,
            distanceToBottom: ConversationTranscriptScrollPolicy.distanceToBottom(
                contentHeight: contentHeight,
                contentOffsetY: offsetY,
                containerHeight: containerHeight,
                bottomInset: bottomInset
            ),
            isInteracting: isInteracting,
            contentHeight: contentHeight,
            containerHeight: containerHeight,
            verticalInsets: topInset + bottomInset,
            atBottomThreshold: 50
        )
    }

    @Test func restingPastEndIsClampedToBottom() {
        #expect(rePinDecision(offsetY: 351) == .rePin(offsetY: 300))
        #expect(rePinDecision(offsetY: 600) == .rePin(offsetY: 300))
        #expect(rePinDecision(offsetY: 350) == .none)
        #expect(rePinDecision(offsetY: 300) == .none)
        #expect(rePinDecision(offsetY: 100) == .none)
        #expect(!ConversationTranscriptScrollPolicy.isScrolledAway(distanceToBottom: -300))
    }

    @Test func bouncingPastEndIsDeferred() {
        #expect(rePinDecision(offsetY: 380, isInteracting: true) == .deferred)
        #expect(rePinDecision(offsetY: 600, isInteracting: true) == .deferred)
        #expect(rePinDecision(offsetY: 380, isInteracting: false) == .rePin(offsetY: 300))
    }

    @Test func shortContentIsNotPastEnd() {
        #expect(rePinDecision(offsetY: 0, contentHeight: 400, containerHeight: 700) == .none)
        #expect(rePinDecision(offsetY: 100, contentHeight: 700, containerHeight: 700) == .none)
        #expect(rePinDecision(offsetY: 0, contentHeight: 650, containerHeight: 780) == .none)
        #expect(rePinDecision(
            offsetY: 0,
            contentHeight: 650,
            containerHeight: 780,
            topInset: 150
        ) == .rePin(offsetY: -130))
    }

    @Test func pastEndClampAccountsForBottomInset() {
        #expect(rePinDecision(offsetY: 400, bottomInset: 20) == .rePin(offsetY: 320))
        #expect(rePinDecision(offsetY: 320, bottomInset: 20) == .none)
    }

    @MainActor
    @Test func restingGeometryConfirmationIncludesAdjustedInsets() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.contentInset = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        scrollView.contentSize = CGSize(width: 390, height: 1000)
        scrollView.contentOffset = CGPoint(x: 0, y: 500)
        let proxy = ScrollViewMomentumProxy()
        proxy.scrollView = scrollView

        guard case let .deferred(first?) = proxy.rePinIfRestingPastEnd(confirming: nil) else {
            Issue.record("first past-end read was not deferred with a geometry")
            return
        }
        #expect(first.topInset == 59)
        #expect(first.bottomInset == 34)
        #expect(first.contentOffsetY == 500)

        scrollView.contentInset.bottom = 100
        scrollView.contentOffset = CGPoint(x: 0, y: 500)
        guard case let .deferred(second?) = proxy.rePinIfRestingPastEnd(confirming: first) else {
            Issue.record("a changed inset was accepted as the confirming read")
            return
        }
        #expect(second.bottomInset == 100)
        #expect(second != first)
        #expect(scrollView.contentOffset.y == 500)

        let clampedOffsetY: CGFloat = 400
        #expect(proxy.rePinIfRestingPastEnd(confirming: second) == .rePinned)
        #expect(scrollView.contentOffset.y == clampedOffsetY)
    }

    @Test func pastEndGeometryIgnoresInteractionState() {
        #expect(ConversationTranscriptScrollPolicy.isPastEnd(
            distanceToBottom: -80,
            contentHeight: 1000,
            containerHeight: 700,
            atBottomThreshold: 50
        ))
        #expect(!ConversationTranscriptScrollPolicy.isPastEnd(
            distanceToBottom: -80,
            contentHeight: 400,
            containerHeight: 700,
            atBottomThreshold: 50
        ))
        #expect(!ConversationTranscriptScrollPolicy.isPastEnd(
            distanceToBottom: -20,
            contentHeight: 1000,
            containerHeight: 700,
            atBottomThreshold: 50
        ))
    }

    typealias ContainerRePin = ConversationTranscriptScrollPolicy.ContainerRePinDecision
}

@Suite @MainActor
struct TranscriptRowHeightCacheTests {
    @Test func cachesOnlyTheLatestSettledHeight() async throws {
        let cache = ConversationTranscriptRowHeightCache(settleDelay: .milliseconds(1))
        let message = assistantMessage(text: "A completed response")

        cache.record(height: 8, for: message, hydratingBlockIds: [])
        cache.record(height: 291, for: message, hydratingBlockIds: [])
        try await waitUntil("latest height settles") {
            cache.height(for: message, hydratingBlockIds: []) == 291
        }
    }

    @Test func contentHydrationAndWidthChangesInvalidateTheHeight() async throws {
        let cache = ConversationTranscriptRowHeightCache(settleDelay: .milliseconds(1))
        let message = assistantMessage(text: "Original")
        cache.record(height: 100, for: message, hydratingBlockIds: [])
        try await waitUntil("original height settles") {
            cache.height(for: message, hydratingBlockIds: []) == 100
        }

        #expect(cache.height(for: assistantMessage(text: "Updated"), hydratingBlockIds: []) == nil)
        #expect(cache.height(for: message, hydratingBlockIds: ["block"]) == nil)
        #expect(cache.height(for: message, hydratingBlockIds: []) == 100)

        cache.updateLayoutWidth(320)
        #expect(cache.height(for: message, hydratingBlockIds: []) == 100)
        cache.updateLayoutWidth(400)
        #expect(cache.height(for: message, hydratingBlockIds: []) == nil)
    }

    @Test func streamingRowsAreNeverCached() {
        let cache = ConversationTranscriptRowHeightCache(settleDelay: .milliseconds(1))
        let message = assistantMessage(text: "Growing", streamingState: .streaming)
        cache.record(height: 100, for: message, hydratingBlockIds: [])

        #expect(cache.height(for: message, hydratingBlockIds: []) == nil)
    }

    @Test func matchingSettledHeightCancelsObsoletePendingMeasurement() async throws {
        let cache = ConversationTranscriptRowHeightCache(settleDelay: .milliseconds(1))
        let message = assistantMessage(text: "Settled")
        cache.record(height: 100, for: message, hydratingBlockIds: [])
        try await waitUntil("initial height settles") {
            cache.height(for: message, hydratingBlockIds: []) == 100
        }

        cache.record(height: 200, for: message, hydratingBlockIds: [])
        cache.record(height: 100, for: message, hydratingBlockIds: [])
        let fence = assistantMessage(text: "Fence", id: "fence")
        cache.record(height: 1, for: fence, hydratingBlockIds: [])
        try await waitUntil("stale measurement window passes") {
            cache.height(for: fence, hydratingBlockIds: []) == 1
        }

        #expect(cache.height(for: message, hydratingBlockIds: []) == 100)
    }

    @Test func cumulativeWidthChangesInvalidateCommittedHeight() async throws {
        let cache = ConversationTranscriptRowHeightCache(settleDelay: .milliseconds(1))
        let message = assistantMessage(text: "Wrapping")
        cache.updateLayoutWidth(320)
        cache.record(height: 100, for: message, hydratingBlockIds: [])
        try await waitUntil("committed height settles") {
            cache.height(for: message, hydratingBlockIds: []) == 100
        }

        cache.updateLayoutWidth(320.4)
        #expect(cache.height(for: message, hydratingBlockIds: []) == 100)
        cache.updateLayoutWidth(320.8)

        #expect(cache.height(for: message, hydratingBlockIds: []) == nil)
    }

    @Test func cumulativeWidthChangesCancelPendingHeight() async throws {
        let cache = ConversationTranscriptRowHeightCache(settleDelay: .milliseconds(50))
        let message = assistantMessage(text: "Pending wrapping")
        cache.updateLayoutWidth(320)
        cache.record(height: 100, for: message, hydratingBlockIds: [])

        cache.updateLayoutWidth(320.4)
        cache.updateLayoutWidth(320.8)
        let fence = assistantMessage(text: "Fence", id: "fence")
        cache.record(height: 1, for: fence, hydratingBlockIds: [])
        try await waitUntil("stale width measurement window passes") {
            cache.height(for: fence, hydratingBlockIds: []) == 1
        }

        #expect(cache.height(for: message, hydratingBlockIds: []) == nil)
    }

    @Test func sameCountReplacementRetiresSettledAndPendingHeight() async throws {
        let cache = ConversationTranscriptRowHeightCache(settleDelay: .milliseconds(20))
        let retired = assistantMessage(text: "Retired", id: "retired")
        let survivor = assistantMessage(text: "Survivor", id: "survivor")
        let replacement = assistantMessage(text: "Replacement", id: "replacement")
        cache.retainMessages(withIDs: [retired.id, survivor.id])
        cache.record(height: 100, for: retired, hydratingBlockIds: [])
        cache.record(height: 200, for: survivor, hydratingBlockIds: [])
        try await waitUntil("original heights settle") {
            cache.height(for: retired, hydratingBlockIds: []) == 100
                && cache.height(for: survivor, hydratingBlockIds: []) == 200
        }

        cache.record(height: 300, for: retired, hydratingBlockIds: [])
        cache.retainMessages(withIDs: [survivor.id, replacement.id])
        #expect(!cache.record(height: 350, for: retired, hydratingBlockIds: []))
        #expect(cache.record(height: 400, for: replacement, hydratingBlockIds: []))
        try await waitUntil("replacement height settles after stale work") {
            cache.height(for: replacement, hydratingBlockIds: []) == 400
        }

        #expect(cache.height(for: retired, hydratingBlockIds: []) == nil)
        #expect(cache.height(for: survivor, hydratingBlockIds: []) == 200)
    }

    @Test func pendingOnlyRetirementCannotRestoreHeight() async throws {
        let cache = ConversationTranscriptRowHeightCache(settleDelay: .milliseconds(20))
        let retired = assistantMessage(text: "Retired", id: "retired")
        let replacement = assistantMessage(text: "Replacement", id: "replacement")
        cache.record(height: 100, for: retired, hydratingBlockIds: [])

        cache.retainMessages(withIDs: [replacement.id])
        cache.record(height: 200, for: replacement, hydratingBlockIds: [])
        try await waitUntil("replacement settles after retired pending work") {
            cache.height(for: replacement, hydratingBlockIds: []) == 200
        }

        #expect(cache.height(for: retired, hydratingBlockIds: []) == nil)
    }

    @Test func measurementEdgeReconcilesNewAndReappearingMessages() async throws {
        let cache = ConversationTranscriptRowHeightCache(settleDelay: .milliseconds(1))
        let survivor = assistantMessage(text: "Survivor", id: "survivor")
        let appended = assistantMessage(text: "Appended", id: "appended")
        cache.retainMessages(withIDs: [survivor.id])
        cache.record(height: 100, for: survivor, hydratingBlockIds: [])
        try await waitUntil("survivor height settles") {
            cache.height(for: survivor, hydratingBlockIds: []) == 100
        }

        #expect(cache.record(
            height: 200,
            for: appended,
            hydratingBlockIds: [],
            retainingMessagesWithIDs: [survivor.id, appended.id]
        ))
        try await waitUntil("first appended measurement settles") {
            cache.height(for: appended, hydratingBlockIds: []) == 200
        }
        #expect(cache.height(for: survivor, hydratingBlockIds: []) == 100)

        cache.retainMessages(withIDs: [])
        #expect(cache.record(
            height: 300,
            for: appended,
            hydratingBlockIds: [],
            retainingMessagesWithIDs: [appended.id]
        ))
        #expect(!cache.record(
            height: 400,
            for: survivor,
            hydratingBlockIds: [],
            retainingMessagesWithIDs: [appended.id]
        ))
        try await waitUntil("first reappearing measurement settles") {
            cache.height(for: appended, hydratingBlockIds: []) == 300
        }
        #expect(cache.height(for: survivor, hydratingBlockIds: []) == nil)
    }

    @Test func emptyTranscriptRetiresSettledAndPendingHeight() async throws {
        let settleDelay = Duration.milliseconds(20)
        let cache = ConversationTranscriptRowHeightCache(settleDelay: settleDelay)
        let message = assistantMessage(text: "Removed")
        cache.retainMessages(withIDs: [message.id])
        cache.record(height: 100, for: message, hydratingBlockIds: [])
        try await waitUntil("height settles before emptying") {
            cache.height(for: message, hydratingBlockIds: []) == 100
        }
        cache.record(height: 200, for: message, hydratingBlockIds: [])

        cache.retainMessages(withIDs: [])
        #expect(!cache.record(height: 300, for: message, hydratingBlockIds: []))
        let replacement = assistantMessage(text: "Replacement", id: "replacement")
        cache.retainMessages(withIDs: [replacement.id])
        #expect(cache.record(height: 1, for: replacement, hydratingBlockIds: []))
        try await waitUntil("replacement settles after emptying") {
            cache.height(for: replacement, hydratingBlockIds: []) == 1
        }

        #expect(cache.height(for: message, hydratingBlockIds: []) == nil)
    }

    private func assistantMessage(
        text: String,
        streamingState: MessageStreamingState = .complete,
        id: String = "message"
    ) -> ConversationMessage {
        ConversationMessage(
            id: id,
            role: .assistant,
            contentBlocks: [ContentBlock(type: .text, text: text)],
            streamingState: streamingState
        )
    }
}

extension ConversationTranscriptScrollPolicyTests {
    @Test(arguments: [CGFloat(0), CGFloat(100)])
    func visibleTranscriptConsumesDeferredEntryWithoutChangingItsViewport(distance: CGFloat) {
        let state = ConversationTranscriptScrollState()
        state.entryScroll = .awaitingScrollView
        let generation = state.initialScrollGeneration
        state.preservePresentedViewport(distanceToBottom: distance)
        #expect(state.initialScrollGeneration != generation, "old entry timers and divider probes are invalid")
        #expect(state.entryScroll == .preserved)
        #expect(state.userIsScrolledAway == (distance > 50))
        let consumed = state.initialScrollGeneration
        state.preservePresentedViewport(distanceToBottom: nil)
        #expect(state.initialScrollGeneration == consumed, "same-binding reappearance cannot position again")
        #expect(state.entryViewportPreserved)
        state.rearmAfterTranscriptEmptied()
        #expect(state.entryScroll == .idle)
    }
}

extension ConversationTranscriptScrollPolicyTests {
    @Test func metadataReadinessIsDecidedAtInitialLayoutRatherThanFirstAppearance() {
        #expect(ConversationTranscriptScrollPolicy.initialScrollStep(
            alreadyPerformed: false,
            scrollViewResolved: false,
            scrollViewWaitElapsed: false,
            entryMetadataReady: false
        ) == .waitForScrollView)
        #expect(ConversationTranscriptScrollPolicy.initialScrollStep(
            alreadyPerformed: false,
            scrollViewResolved: true,
            scrollViewWaitElapsed: false,
            entryMetadataReady: true
        ) == .perform, "metadata arriving before initial layout retains normal unread/bottom entry")
        #expect(ConversationTranscriptScrollPolicy.initialScrollStep(
            alreadyPerformed: false,
            scrollViewResolved: true,
            scrollViewWaitElapsed: false,
            entryMetadataReady: false
        ) == .preserveViewport, "already presented rows take precedence over later authority")
    }

    @Test func gestureOrCompletedEntryCannotBeReopenedByLaterMetadata() {
        for ready in [false, true] {
            #expect(ConversationTranscriptScrollPolicy.initialScrollStep(
                alreadyPerformed: true,
                scrollViewResolved: true,
                scrollViewWaitElapsed: true,
                entryMetadataReady: ready
            ) == .skip)
        }
        #expect(ConversationTranscriptScrollPolicy.initialScrollStep(
            alreadyPerformed: false,
            scrollViewResolved: false,
            scrollViewWaitElapsed: true,
            entryMetadataReady: false
        ) == .preserveViewport)
    }
}

extension ConversationTranscriptScrollPolicyTests {
    @Test(arguments: [false, true])
    func disappearingBeforeEntrySettlesAllowsANewEntry(performed: Bool) {
        let state = ConversationTranscriptScrollState()
        state.entryScroll = performed ? .settling : .awaitingScrollView
        let previousGeneration = state.initialScrollGeneration

        state.suspendEntryScroll()

        #expect(state.entryScroll == .idle)
        #expect(state.initialScrollGeneration == previousGeneration + 1)
        state.applyDividerProbe(distanceToBottom: 100, generation: previousGeneration)
        #expect(!state.userIsScrolledAway)
        state.applyDividerProbe(distanceToBottom: 100, generation: state.initialScrollGeneration)
        #expect(state.userIsScrolledAway)
    }

    @Test func disappearingAfterEntryKeepsTheReadersPositionAndGestureClaim() {
        let state = ConversationTranscriptScrollState()
        state.preservePresentedViewport(distanceToBottom: 100)
        state.forcedFollowTakenOverByGesture = true
        let previousGeneration = state.initialScrollGeneration

        state.suspendEntryScroll()

        #expect(state.entryScroll == .preserved)
        #expect(state.userIsScrolledAway)
        #expect(state.forcedFollowTakenOverByGesture)
        #expect(state.initialScrollGeneration == previousGeneration + 1)
    }
}
