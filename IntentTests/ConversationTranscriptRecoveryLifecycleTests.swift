import CoreGraphics
import Testing
@testable import Intent

/// Transition-level tests of the recovery lifecycle reducer: each event
/// against each owner/fallback state it reads, with the contract's
/// invariants asserted on every transition through `step`.
struct ConversationTranscriptRecoveryLifecycleTests {
    private typealias Lifecycle = ConversationTranscriptRecoveryLifecycle
    private typealias State = Lifecycle.State
    private typealias Event = Lifecycle.Event
    private typealias Effect = Lifecycle.Effect
    private typealias FollowToken = Lifecycle.FollowToken
    private typealias RecoveryToken = Lifecycle.RecoveryToken

    private let f1 = FollowToken(id: 1)
    private let f2 = FollowToken(id: 2)
    private let r1 = RecoveryToken(id: 1)
    private let r2 = RecoveryToken(id: 2)
    private let staleFollow = FollowToken(id: 99)
    private let staleRecovery = RecoveryToken(id: 99)

    // MARK: - Harness

    /// Runs one transition, asserts the invariants and advances `state`.
    @discardableResult
    private func step(
        _ state: inout State, _ event: Event, sourceLocation: SourceLocation = #_sourceLocation
    ) -> [Effect] {
        let before = state
        let (after, effects) = Lifecycle.transition(before, event)
        checkInvariants(before: before, event: event, after: after, effects: effects, sourceLocation: sourceLocation)
        state = after
        return effects
    }

    private func checkInvariants(
        before: State, event: Event, after: State, effects: [Effect], sourceLocation: SourceLocation
    ) {
        // Well-formed: a transferred fallback names the follow that owns.
        if case .transferred(let follow) = after.fallback {
            #expect(followOwner(of: after) == follow, "fallback transferred to a non-owner", sourceLocation: sourceLocation)
        }
        // Single owner: the armed recovery is never also the owner.
        if let armed = after.armedRecovery {
            #expect(after.owner != .recovery(armed), "armed recovery also owns", sourceLocation: sourceLocation)
        }
        #expect(after.nextTokenId >= before.nextTokenId, "token counter went backwards", sourceLocation: sourceLocation)
        // Stale identity: a token that is not current changes nothing.
        if tokenIsCurrent(event, in: before) == false {
            #expect(after == before, "stale token changed state", sourceLocation: sourceLocation)
            #expect(effects.isEmpty, "stale token produced effects", sourceLocation: sourceLocation)
        }
        // A scroll is only ever issued by an owner (invariants 1, 5).
        if effects.contains(where: isScroll) {
            #expect(after.owner != .idle, "scroll issued with no owner", sourceLocation: sourceLocation)
        }
        if case .recoveryStep = event, case .follow = before.owner {
            #expect(!effects.contains(where: isScroll), "correction scrolled over a follow", sourceLocation: sourceLocation)
        }
        // Give-up over an unrealized end resolves (invariant 2).
        if case .recoveryFinished(let token, .giveUp, _) = event, before.currentRecovery == token, !before.isEndRealized {
            let shown = effects.contains(.showGoToEnd)
            var transferred = false
            if case .transferred(let follow) = after.fallback { transferred = followOwner(of: after) == follow }
            #expect(shown != transferred, "give-up neither shown nor transferred (or both)", sourceLocation: sourceLocation)
            if shown { #expect(after.owner == .idle, sourceLocation: sourceLocation) }
        }
        // Realization gate (invariant 4).
        if case .endRealized(true) = event {
            #expect(effects.contains(.replayLiveEdge(isInteracting: nil)), sourceLocation: sourceLocation)
        }
        // A terminal for the transferred follow discharges it (invariant 3).
        if case .transferred(let follow) = before.fallback {
            switch event {
            case .followFinished(follow, _):
                #expect(after.fallback == .none, "terminal left the transfer", sourceLocation: sourceLocation)
            case .followCancelledByGesture:
                #expect(after.fallback == .none, "takeover left the transfer", sourceLocation: sourceLocation)
            case .endDerealized, .endRealized, .followRequested, .followDue, .followFinished, .explicitClaim,
                 .recoveryStep, .recoveryPagedUp, .recoveryFinished, .viewDisappeared:
                break
            }
        }
    }

    private func followOwner(of state: State) -> FollowToken? {
        if case .follow(let token, _) = state.owner { return token }
        return nil
    }

    /// nil for token-less events.
    private func tokenIsCurrent(_ event: Event, in state: State) -> Bool? {
        switch event {
        case .followDue(let token, _), .followFinished(let token, _):
            return followOwner(of: state) == token
        case .recoveryStep(let token, _), .recoveryPagedUp(let token, _), .recoveryFinished(let token, _, _):
            return state.currentRecovery == token
        case .endDerealized, .endRealized, .followRequested, .followCancelledByGesture, .explicitClaim, .viewDisappeared:
            return nil
        }
    }

    private func isScroll(_ effect: Effect) -> Bool {
        switch effect {
        case .scrollToEnd, .pageUp: return true
        case .startFollowTask, .cancelFollowTask, .startRecoveryTask, .cancelRecoveryTask, .replayLiveEdge,
             .showGoToEnd, .recordRecoveryOutcome, .log:
            return false
        }
    }

    private func isLog(_ effect: Effect) -> Bool {
        if case .log = effect { return true }
        return false
    }

    private func nonLog(_ effects: [Effect]) -> [Effect] { effects.filter { !isLog($0) } }

    private func logs(_ effects: [Effect]) -> [String] {
        effects.compactMap { if case .log(let message) = $0 { return message } else { return nil } }
    }

    private func state(
        owner: Lifecycle.ViewportOwner = .idle,
        armed: RecoveryToken? = nil,
        fallback: Lifecycle.GiveUpFallback = .none,
        realized: Bool = false,
        next: Int = 3
    ) -> State {
        State(owner: owner, armedRecovery: armed, fallback: fallback, isEndRealized: realized, nextTokenId: next)
    }

    // MARK: - End row

    @Test func freshStateIsIdleAndUnrealized() {
        let fresh = State()
        #expect(fresh.owner == .idle)
        #expect(fresh.armedRecovery == nil)
        #expect(fresh.fallback == .none)
        #expect(!fresh.isEndRealized)
        #expect(!fresh.isFollowing)
        #expect(fresh.currentRecovery == nil)
    }

    @Test func endDerealizedArmsExactlyOneRecovery() {
        var s = State()
        #expect(step(&s, .endDerealized) == [.startRecoveryTask(r1)])
        #expect(s.armedRecovery == r1)
        #expect(s.owner == .idle)
        #expect(!s.isFollowing)
        // A recovery already polling keeps its budget.
        #expect(step(&s, .endDerealized).isEmpty)
        #expect(s.armedRecovery == r1)
    }

    @Test func endDerealizedArmsNothingWhileARecoveryOwns() {
        var s = state(owner: .recovery(r1), realized: true)
        #expect(step(&s, .endDerealized).isEmpty)
        #expect(!s.isEndRealized)
        #expect(s.owner == .recovery(r1))
        #expect(s.armedRecovery == nil)
    }

    @Test func endDerealizedArmsUnderAFollowOwner() {
        var s = state(owner: .follow(f1, forced: true), realized: true)
        #expect(step(&s, .endDerealized) == [.startRecoveryTask(RecoveryToken(id: 3))])
        #expect(s.owner == .follow(f1, forced: true))
        #expect(s.armedRecovery == RecoveryToken(id: 3))
        #expect(s.isFollowing)
    }

    @Test func endRealizedReplaysOnlyWhenScrolledAway() {
        var s = state(armed: r1)
        #expect(step(&s, .endRealized(userIsScrolledAway: false)).isEmpty)
        #expect(s.isEndRealized)
        #expect(s.armedRecovery == r1)
        s.isEndRealized = false
        #expect(step(&s, .endRealized(userIsScrolledAway: true)) == [.replayLiveEdge(isInteracting: nil)])
        #expect(s.isEndRealized)
        #expect(s.armedRecovery == r1)
    }

    // MARK: - followRequested

    @Test(arguments: [false, true]) func followRequestedFromIdleStartsAFollow(forced: Bool) {
        var s = State()
        #expect(step(&s, .followRequested(forced: forced)) == [.startFollowTask(f1, forced: forced)])
        #expect(s.owner == .follow(f1, forced: forced))
        #expect(s.isFollowing)
        #expect(s.nextTokenId == 2)
    }

    @Test func automaticFollowNeverPreemptsAForcedOne() {
        var s = state(owner: .follow(f1, forced: true), armed: r2)
        let before = s
        #expect(step(&s, .followRequested(forced: false)).isEmpty)
        #expect(s == before)
    }

    @Test(arguments: [(false, false), (false, true), (true, true)])
    func followReplacesThePendingFollow(current: Bool, requested: Bool) {
        var s = state(owner: .follow(f1, forced: current))
        let replacement = FollowToken(id: 3)
        #expect(step(&s, .followRequested(forced: requested)) == [
            .cancelFollowTask(f1), .startFollowTask(replacement, forced: requested),
        ])
        #expect(s.owner == .follow(replacement, forced: requested))
        #expect(s.fallback == .none)
    }

    @Test func replacingFollowInheritsTheTransferredGiveUp() {
        var s = state(owner: .follow(f1, forced: false), fallback: .transferred(to: f1))
        let replacement = FollowToken(id: 3)
        step(&s, .followRequested(forced: true))
        #expect(s.fallback == .transferred(to: replacement))
        // The replaced follow's terminal is stale and cannot discharge it.
        #expect(step(&s, .followFinished(f1, .dropped)).isEmpty)
        #expect(s.fallback == .transferred(to: replacement))
        // The replacement's does, exactly once.
        #expect(step(&s, .followFinished(replacement, .yielded)).contains(.showGoToEnd))
        #expect(s.fallback == .none)
    }

    @Test func followRequestedDemotesAnOwningRecoveryToArmed() {
        var s = state(owner: .recovery(r1))
        let follow = FollowToken(id: 3)
        #expect(step(&s, .followRequested(forced: false)) == [.startFollowTask(follow, forced: false)])
        #expect(s.owner == .follow(follow, forced: false))
        #expect(s.armedRecovery == r1)
        #expect(s.currentRecovery == r1)
    }

    @Test func followRequestedKeepsAnArmedRecovery() {
        var s = state(armed: r1)
        step(&s, .followRequested(forced: true))
        #expect(s.armedRecovery == r1)
        #expect(s.owner == .follow(FollowToken(id: 3), forced: true))
    }

    // MARK: - followDue

    @Test(arguments: [false, true]) func followDueThatExecutesScrollsToEnd(forced: Bool) {
        var s = state(owner: .follow(f1, forced: forced), armed: r2)
        let before = s
        #expect(step(&s, .followDue(f1, execute: true)) == [.scrollToEnd])
        #expect(s == before)
    }

    @Test func droppedAutomaticFollowIsSilentWhenDue() {
        var s = state(owner: .follow(f1, forced: false))
        #expect(step(&s, .followDue(f1, execute: false)).isEmpty)
        #expect(s.owner == .follow(f1, forced: false))
    }

    @Test func yieldedForcedFollowReplaysTheLiveEdgeAsTheGestureSample() {
        var s = state(owner: .follow(f1, forced: true))
        let effects = step(&s, .followDue(f1, execute: false))
        #expect(nonLog(effects) == [.replayLiveEdge(isInteracting: true)])
        #expect(logs(effects) == ["[SCROLL] Forced follow yielded to the user's gesture"])
        #expect(s.owner == .follow(f1, forced: true))
    }

    // MARK: - followFinished

    @Test func executedAutomaticFollowReplaysTheEdgeItSwallowed() {
        var s = state(owner: .follow(f1, forced: false), realized: true)
        #expect(step(&s, .followFinished(f1, .executed(nil))) == [.replayLiveEdge(isInteracting: nil)])
        #expect(s.owner == .idle)
        #expect(!s.isFollowing)
    }

    @Test func executedForcedFollowReplaysNothing() {
        var s = state(owner: .follow(f1, forced: true), realized: true)
        #expect(step(&s, .followFinished(f1, .executed(.landed))).isEmpty)
        #expect(s.owner == .idle)
    }

    @Test func executedFollowOverAnUnrealizedEndReArmsTheRecovery() {
        var s = state(owner: .follow(f1, forced: true), realized: false)
        #expect(step(&s, .followFinished(f1, .executed(.giveUp))) == [.startRecoveryTask(RecoveryToken(id: 3))])
        #expect(s.armedRecovery == RecoveryToken(id: 3))
        #expect(s.owner == .idle)
    }

    @Test func executedFollowDoesNotDoubleArmARecoveryAlreadyPolling() {
        var s = state(owner: .follow(f1, forced: false), armed: r2, realized: false)
        #expect(step(&s, .followFinished(f1, .executed(nil))) == [.replayLiveEdge(isInteracting: nil)])
        #expect(s.armedRecovery == r2)
        #expect(s.nextTokenId == 3)
    }

    @Test func executedFollowDischargesATransferWithNoGoToEndAndReArms() {
        var s = state(owner: .follow(f1, forced: true), fallback: .transferred(to: f1), realized: false)
        let effects = step(&s, .followFinished(f1, .executed(.landed)))
        #expect(effects == [.startRecoveryTask(RecoveryToken(id: 3))])
        #expect(s.fallback == .none)
    }

    @Test(arguments: [
        ConversationTranscriptScrollPolicy.FollowTerminal.dropped, .yielded, .cancelled, .replaced,
    ]) func unexecutedFollowWithATransferOverAnUnrealizedEndShowsGoToEnd(
        terminal: ConversationTranscriptScrollPolicy.FollowTerminal
    ) {
        for forced in [false, true] {
            var s = state(owner: .follow(f1, forced: forced), fallback: .transferred(to: f1), realized: false)
            let effects = step(&s, .followFinished(f1, terminal))
            #expect(nonLog(effects) == [.showGoToEnd])
            #expect(logs(effects) == [
                "[SCROLL] End recovery gave up and the follow it deferred to did not execute; showing Go to End",
            ])
            #expect(s.fallback == .none)
            #expect(s.owner == .idle)
            #expect(s.armedRecovery == nil)
        }
    }

    @Test func unexecutedFollowWithATransferOverARealizedEndClearsItSilently() {
        var auto = state(owner: .follow(f1, forced: false), fallback: .transferred(to: f1), realized: true)
        #expect(step(&auto, .followFinished(f1, .dropped)) == [.replayLiveEdge(isInteracting: nil)])
        #expect(auto.fallback == .none)
        var forced = state(owner: .follow(f1, forced: true), fallback: .transferred(to: f1), realized: true)
        #expect(step(&forced, .followFinished(f1, .yielded)).isEmpty)
        #expect(forced.fallback == .none)
    }

    @Test func droppedAutomaticFollowWithoutATransferReplaysTheLiveEdge() {
        var s = state(owner: .follow(f1, forced: false), armed: r2, realized: false)
        #expect(step(&s, .followFinished(f1, .dropped)) == [.replayLiveEdge(isInteracting: nil)])
        #expect(s.armedRecovery == r2)
        #expect(s.owner == .idle)
    }

    @Test func yieldedForcedFollowWithoutATransferDrainsSilently() {
        var s = state(owner: .follow(f1, forced: true), realized: false)
        #expect(step(&s, .followFinished(f1, .yielded)).isEmpty)
        #expect(s.owner == .idle)
        #expect(s.armedRecovery == nil)
    }

    @Test func aTransferIsDischargedExactlyOnce() {
        var s = state(owner: .follow(f1, forced: false), fallback: .transferred(to: f1), realized: false)
        #expect(step(&s, .followFinished(f1, .dropped)).contains(.showGoToEnd))
        let after = s
        #expect(step(&s, .followFinished(f1, .dropped)).isEmpty)
        #expect(step(&s, .followCancelledByGesture).isEmpty)
        #expect(s == after)
    }

    // MARK: - followCancelledByGesture

    @Test func gestureCancelsAForcedFollowAndLatchesTheTakeover() {
        var s = state(owner: .follow(f1, forced: true), realized: true)
        let effects = step(&s, .followCancelledByGesture)
        #expect(nonLog(effects) == [.cancelFollowTask(f1)])
        #expect(logs(effects) == ["[SCROLL] Forced follow cancelled: the user took over"])
        #expect(s.owner == .idle)
    }

    @Test func gestureCancelsAnAutomaticFollowWithoutTheLatchLog() {
        var s = state(owner: .follow(f1, forced: false), realized: true)
        #expect(step(&s, .followCancelledByGesture) == [.cancelFollowTask(f1)])
        #expect(s.owner == .idle)
    }

    @Test func gestureCancelsTheFollowAndTheArmedRecoveryTogether() {
        var s = state(owner: .follow(f1, forced: true), armed: r2, realized: false)
        #expect(nonLog(step(&s, .followCancelledByGesture)) == [.cancelFollowTask(f1), .cancelRecoveryTask(r2)])
        #expect(s.owner == .idle)
        #expect(s.armedRecovery == nil)
        #expect(s.currentRecovery == nil)
    }

    @Test func gestureCancelsAnOwningCorrection() {
        var s = state(owner: .recovery(r1), realized: false)
        #expect(step(&s, .followCancelledByGesture) == [.cancelRecoveryTask(r1)])
        #expect(s.owner == .idle)
        #expect(s.armedRecovery == nil)
    }

    @Test func gestureWithNothingPendingChangesNothing() {
        var s = state(realized: true)
        let before = s
        #expect(step(&s, .followCancelledByGesture).isEmpty)
        #expect(s == before)
    }

    @Test func gestureDischargesATransferOverAnUnrealizedEndAsGoToEnd() {
        var s = state(owner: .follow(f1, forced: false), armed: r2, fallback: .transferred(to: f1), realized: false)
        let effects = step(&s, .followCancelledByGesture)
        #expect(nonLog(effects) == [.cancelFollowTask(f1), .cancelRecoveryTask(r2), .showGoToEnd])
        #expect(s.fallback == .none)
        #expect(s.owner == .idle)
    }

    @Test func gestureDischargesATransferOverARealizedEndSilently() {
        var s = state(owner: .follow(f1, forced: true), fallback: .transferred(to: f1), realized: true)
        #expect(nonLog(step(&s, .followCancelledByGesture)) == [.cancelFollowTask(f1)])
        #expect(s.fallback == .none)
    }

    // MARK: - explicitClaim / viewDisappeared

    @Test(arguments: [ConversationTranscriptRecoveryLifecycle.Event.explicitClaim, .viewDisappeared])
    func claimCancelsTheRecoveryOnly(event: ConversationTranscriptRecoveryLifecycle.Event) {
        var armedUnderFollow = state(owner: .follow(f1, forced: true), armed: r2, fallback: .transferred(to: f1))
        #expect(step(&armedUnderFollow, event) == [.cancelRecoveryTask(r2)])
        #expect(armedUnderFollow.owner == .follow(f1, forced: true))
        #expect(armedUnderFollow.fallback == .transferred(to: f1))
        #expect(armedUnderFollow.armedRecovery == nil)

        var owning = state(owner: .recovery(r1))
        #expect(step(&owning, event) == [.cancelRecoveryTask(r1)])
        #expect(owning.owner == .idle)

        var idle = state(owner: .follow(f1, forced: false))
        let before = idle
        #expect(step(&idle, event).isEmpty)
        #expect(idle == before)
    }

    // MARK: - recoveryStep / recoveryPagedUp

    @Test func settlingStepIsSilent() {
        var armed = state(armed: r1)
        let before = armed
        #expect(step(&armed, .recoveryStep(r1, .settling)).isEmpty)
        #expect(armed == before)
        var owning = state(owner: .recovery(r1))
        #expect(step(&owning, .recoveryStep(r1, .settling)).isEmpty)
        #expect(owning.owner == .recovery(r1))
    }

    @Test func followToEndCorrectionClaimsTheViewport() {
        var s = state(armed: r1)
        let effects = step(&s, .recoveryStep(r1, .followToEnd))
        #expect(nonLog(effects) == [.scrollToEnd])
        #expect(logs(effects) == ["[SCROLL] End row off screen short of the bottom; following to the end"])
        #expect(s.owner == .recovery(r1))
        #expect(s.armedRecovery == nil)
        #expect(s.isFollowing)
        // A second correction keeps the claim.
        #expect(nonLog(step(&s, .recoveryStep(r1, .followToEnd))) == [.scrollToEnd])
        #expect(s.owner == .recovery(r1))
    }

    @Test func recoverCorrectionClaimsTheViewportAndPagesUp() {
        var s = state(armed: r1)
        let effects = step(&s, .recoveryStep(r1, .recover(pageOffsetY: 120)))
        #expect(nonLog(effects) == [.pageUp(offsetY: 120)])
        #expect(logs(effects) == ["[SCROLL] Blank viewport at the bottom; paging up and following back"])
        #expect(s.owner == .recovery(r1))
        #expect(s.armedRecovery == nil)
    }

    @Test func correctionsAreRefusedWhileAFollowOwns() {
        for continuation in [
            Lifecycle.RecoveryContinuation.followToEnd, .recover(pageOffsetY: 40),
        ] {
            var s = state(owner: .follow(f1, forced: false), armed: r2)
            let before = s
            #expect(step(&s, .recoveryStep(r2, continuation)).isEmpty)
            #expect(s == before)
        }
    }

    @Test func pagedUpCorrectionFollowsBackOnlyWhileItOwns() {
        var owning = state(owner: .recovery(r1))
        #expect(step(&owning, .recoveryPagedUp(r1, mayFollowBack: true)) == [.scrollToEnd])
        #expect(owning.owner == .recovery(r1))
        let yielded = step(&owning, .recoveryPagedUp(r1, mayFollowBack: false))
        #expect(nonLog(yielded).isEmpty)
        #expect(logs(yielded) == ["[SCROLL] End recovery yielded the paged-up viewport to the user"])
        #expect(owning.owner == .recovery(r1))
        // Demoted under a follow requested meanwhile: the token is current
        // but no longer owns, so no follow back is issued over the follow.
        var demoted = state(owner: .follow(f1, forced: true), armed: r2)
        let before = demoted
        #expect(step(&demoted, .recoveryPagedUp(r2, mayFollowBack: true)).isEmpty)
        #expect(demoted == before)
    }

    // MARK: - recoveryFinished

    @Test func giveUpWithNoFollowShowsGoToEnd() {
        var s = state(owner: .recovery(r1), realized: false)
        let effects = step(&s, .recoveryFinished(r1, .giveUp, corrections: 2))
        #expect(nonLog(effects) == [.recordRecoveryOutcome(.giveUp, corrections: 2), .showGoToEnd])
        #expect(logs(effects) == ["[SCROLL] End recovery gave up over an unrealized end row; showing Go to End"])
        #expect(s.owner == .idle)
        #expect(s.fallback == .none)
        #expect(s.currentRecovery == nil)
    }

    @Test func giveUpUnderAFollowTransfersToThatFollow() {
        var s = state(owner: .follow(f1, forced: false), armed: r2, realized: false)
        let effects = step(&s, .recoveryFinished(r2, .giveUp, corrections: 3))
        #expect(effects == [.recordRecoveryOutcome(.giveUp, corrections: 3), .replayLiveEdge(isInteracting: nil)])
        #expect(s.fallback == .transferred(to: f1))
        #expect(s.owner == .follow(f1, forced: false))
        #expect(s.armedRecovery == nil)
    }

    @Test(arguments: [
        ConversationTranscriptScrollPolicy.UnrealizedEndRecoveryTerminal.notNeeded, .yieldToUser,
    ]) func recoveredAndYieldedDrainsReplayTheLiveEdge(
        terminal: ConversationTranscriptScrollPolicy.UnrealizedEndRecoveryTerminal
    ) {
        var owning = state(owner: .recovery(r1))
        #expect(step(&owning, .recoveryFinished(r1, terminal, corrections: 1)) == [
            .recordRecoveryOutcome(terminal, corrections: 1), .replayLiveEdge(isInteracting: nil),
        ])
        #expect(owning.owner == .idle)
        var armed = state(owner: .follow(f1, forced: true), armed: r2)
        #expect(step(&armed, .recoveryFinished(r2, terminal, corrections: 0)) == [.replayLiveEdge(isInteracting: nil)])
        #expect(armed.owner == .follow(f1, forced: true))
        #expect(armed.armedRecovery == nil)
    }

    @Test func aRecoveryThatCorrectedNothingRecordsNoOutcome() {
        var s = state(armed: r1, realized: true)
        #expect(step(&s, .recoveryFinished(r1, .notNeeded, corrections: 0)) == [.replayLiveEdge(isInteracting: nil)])
        #expect(s.armedRecovery == nil)
    }

    // MARK: - Identity

    @Test func staleTokensChangeNothing() {
        let states = [
            State(),
            state(owner: .follow(f1, forced: true), armed: r2, fallback: .transferred(to: f1)),
            state(owner: .recovery(r1)),
        ]
        let events: [Event] = [
            .followDue(staleFollow, execute: true), .followFinished(staleFollow, .executed(nil)),
            .followFinished(staleFollow, .dropped), .recoveryStep(staleRecovery, .followToEnd),
            .recoveryStep(staleRecovery, .recover(pageOffsetY: 10)), .recoveryPagedUp(staleRecovery, mayFollowBack: true),
            .recoveryFinished(staleRecovery, .giveUp, corrections: 1),
            .recoveryFinished(staleRecovery, .notNeeded, corrections: 0),
        ]
        for original in states {
            for event in events {
                var s = original
                #expect(step(&s, event).isEmpty, "\(event)")
                #expect(s == original, "\(event)")
            }
        }
    }

    @Test func aGestureTakeoverMakesEveryEarlierTokenStale() {
        var s = State()
        step(&s, .endDerealized)
        step(&s, .recoveryStep(r1, .recover(pageOffsetY: 80)))
        #expect(s.owner == .recovery(r1))
        #expect(step(&s, .followCancelledByGesture) == [.cancelRecoveryTask(r1)])
        #expect(step(&s, .recoveryPagedUp(r1, mayFollowBack: true)).isEmpty)
        #expect(step(&s, .recoveryStep(r1, .followToEnd)).isEmpty)
        #expect(step(&s, .recoveryFinished(r1, .giveUp, corrections: 1)).isEmpty)

        step(&s, .followRequested(forced: true))
        #expect(s.owner == .follow(f2, forced: true))
        step(&s, .followCancelledByGesture)
        #expect(step(&s, .followDue(f2, execute: true)).isEmpty)
        #expect(step(&s, .followFinished(f2, .executed(.landed))).isEmpty)
        #expect(s.owner == .idle)
        #expect(s.currentRecovery == nil)
    }

    @Test func tokensAreMintedFromOneMonotonicCounter() {
        var s = State()
        #expect(step(&s, .endDerealized) == [.startRecoveryTask(RecoveryToken(id: 1))])
        #expect(step(&s, .followRequested(forced: false)) == [.startFollowTask(FollowToken(id: 2), forced: false)])
        #expect(nonLog(step(&s, .followRequested(forced: true))) == [
            .cancelFollowTask(FollowToken(id: 2)), .startFollowTask(FollowToken(id: 3), forced: true),
        ])
        step(&s, .explicitClaim)
        #expect(step(&s, .followFinished(FollowToken(id: 3), .executed(.landed))) == [
            .startRecoveryTask(RecoveryToken(id: 4)),
        ])
        #expect(s.nextTokenId == 5)
    }

    // MARK: - Tables

    /// Every well-formed owner / armed / fallback combination the two
    /// terminal events can meet. `f1` is the follow, `r2` the recovery.
    private var terminalStates: [State] {
        var states: [State] = []
        for realized in [false, true] {
            for armed in [nil, r2] {
                states.append(state(owner: .idle, armed: armed, realized: realized))
                for forced in [false, true] {
                    for fallback in [Lifecycle.GiveUpFallback.none, .transferred(to: f1)] {
                        states.append(state(owner: .follow(f1, forced: forced), armed: armed, fallback: fallback, realized: realized))
                    }
                }
            }
            states.append(state(owner: .recovery(r2), realized: realized))
        }
        return states
    }

    @Test func recoveryFinishedTable() {
        var cases = 0
        for original in terminalStates {
            for terminal in [Lifecycle.RecoveryTerminal.notNeeded, .giveUp, .yieldToUser] {
                for corrections in [0, 2] {
                    for token in [r2, staleRecovery] {
                        cases += 1
                        var s = original
                        let effects = nonLog(step(&s, .recoveryFinished(token, terminal, corrections: corrections)))
                        guard original.currentRecovery == token else {
                            #expect(effects.isEmpty)
                            #expect(s == original)
                            continue
                        }
                        var expected = original
                        var expectedEffects: [Effect] = []
                        if corrections > 0 {
                            expectedEffects.append(.recordRecoveryOutcome(terminal, corrections: corrections))
                        }
                        expected.armedRecovery = nil
                        if expected.owner == .recovery(token) { expected.owner = .idle }
                        switch terminal {
                        case .giveUp:
                            if let follow = followOwner(of: expected) {
                                expected.fallback = .transferred(to: follow)
                                expectedEffects.append(.replayLiveEdge(isInteracting: nil))
                            } else {
                                expectedEffects.append(.showGoToEnd)
                            }
                        case .notNeeded, .yieldToUser:
                            expectedEffects.append(.replayLiveEdge(isInteracting: nil))
                        }
                        #expect(s == expected, "\(original) \(terminal) \(corrections)")
                        #expect(effects == expectedEffects, "\(original) \(terminal) \(corrections)")
                    }
                }
            }
        }
        #expect(cases == 22 * 3 * 2 * 2)
    }

    @Test func followFinishedTable() {
        let terminals: [Lifecycle.FollowTerminal] = [
            .executed(nil), .executed(.landed), .dropped, .yielded, .cancelled, .replaced,
        ]
        var cases = 0
        let followStates = terminalStates.filter {
            if case .recovery = $0.owner { return false }
            return true
        }
        for original in followStates {
            for terminal in terminals {
                for token in [f1, staleFollow] {
                    cases += 1
                    var s = original
                    let effects = nonLog(step(&s, .followFinished(token, terminal)))
                    guard case .follow(token, let forced) = original.owner else {
                        #expect(effects.isEmpty)
                        #expect(s == original)
                        continue
                    }
                    var expected = original
                    var expectedEffects: [Effect] = []
                    expected.owner = .idle
                    let transferred = original.fallback == .transferred(to: token)
                    expected.fallback = .none
                    switch terminal {
                    case .executed:
                        if !forced { expectedEffects.append(.replayLiveEdge(isInteracting: nil)) }
                        if !original.isEndRealized, original.armedRecovery == nil {
                            let armed = RecoveryToken(id: original.nextTokenId)
                            expected.armedRecovery = armed
                            expected.nextTokenId += 1
                            expectedEffects.append(.startRecoveryTask(armed))
                        }
                    case .dropped, .yielded, .cancelled, .replaced:
                        if transferred, !original.isEndRealized {
                            expectedEffects.append(.showGoToEnd)
                        } else if !forced {
                            expectedEffects.append(.replayLiveEdge(isInteracting: nil))
                        }
                    }
                    #expect(s == expected, "\(original) \(terminal)")
                    #expect(effects == expectedEffects, "\(original) \(terminal)")
                }
            }
        }
        #expect(cases == 20 * 6 * 2)
    }
}
