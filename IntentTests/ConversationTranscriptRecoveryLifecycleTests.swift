import CoreGraphics
import Testing
@testable import Intent

/// Transition-level tests of the recovery lifecycle reducer: each event
/// against each owner/fallback state it reads, with the contract's
/// invariants asserted on every transition through `step` — and, under
/// "Sequences", each #350 handoff defect replayed as one deterministic
/// event sequence through `LifecycleHarness`, which executes the effects
/// against scripted geometry the way the view does.
///
/// Mutation checks (each must fail deterministically):
/// - Removing the transfer discharge in `transition` (the
///   `dischargeFallback` call in `followFinished` / `followCancelledByGesture`)
///   fails `aGiveUpUnderAPendingAutomaticFollowIsShownWhenThatFollowIsDropped`
///   and `aTransferredGiveUpIsDischargedOnceByYieldCancelOrReplace`: the
///   drain replays the edge as a raw re-pin (`rePins`) with Go to End hidden.
/// - Removing the realization gate — the `isEndRealized` guard in
///   `ConversationTranscriptScrollPolicy.scrolledAwayTransition`, or the
///   `replayLiveEdge` the reducer's `endRealized` issues — fails
///   `anAtBottomEdgeOverTheBlankKeepsGoToEndUntilTheMarkerRealizes`: the
///   blank's at-bottom edge clears the flag early, or the realization never
///   does.
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
        // Single owner: the armed recovery is never also the owner, and a
        // demoted one only exists under the follow that demoted it.
        if let armed = after.armedRecovery {
            #expect(after.owner != .recovery(armed.token), "armed recovery also owns", sourceLocation: sourceLocation)
            if case .demoted = armed {
                #expect(followOwner(of: after) != nil, "demoted recovery with no follow owning", sourceLocation: sourceLocation)
            }
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
        // A terminal for the transferred follow discharges it, with the
        // effect of that terminal: Go to End once if it did not execute over
        // a still-unrealized end, nothing if it did or the end realized, and
        // an executed drain over an unrealized end re-arms (invariant 3).
        if case .transferred(let follow) = before.fallback {
            var executed: Bool?
            switch event {
            case .followFinished(follow, .executed):
                executed = true
            case .followFinished(follow, .dropped), .followFinished(follow, .yielded),
                 .followFinished(follow, .cancelled), .followFinished(follow, .replaced):
                executed = false
            case .followCancelledByGesture:
                executed = false
            case .followRequested:
                // A replacing follow inherits the transfer; an ignored request
                // (automatic under forced) leaves it with the same owner.
                if let owner = followOwner(of: after) {
                    #expect(after.fallback == .transferred(to: owner), "follow request did not carry the transfer to the owner", sourceLocation: sourceLocation)
                } else {
                    Issue.record("follow request over a transfer left no follow owning", sourceLocation: sourceLocation)
                }
            case .endDerealized, .endRealized, .followDue, .followFinished, .explicitClaim,
                 .recoveryStep, .recoveryPagedUp, .recoveryFinished, .viewDisappeared:
                break
            }
            if let executed {
                #expect(after.fallback == .none, "terminal left the transfer", sourceLocation: sourceLocation)
                let shownByTerminal = effects.filter { $0 == .showGoToEnd }.count
                if !executed, !before.isEndRealized {
                    #expect(shownByTerminal == 1, "unexecuted terminal over an unrealized end did not show Go to End", sourceLocation: sourceLocation)
                } else {
                    #expect(shownByTerminal == 0, "Go to End shown by an executed drain or over a realized end", sourceLocation: sourceLocation)
                }
                if executed, !before.isEndRealized, before.currentRecovery == nil {
                    #expect(effects.contains(where: isStartRecovery), "executed drain over an unrealized end did not re-arm", sourceLocation: sourceLocation)
                }
            }
        }
        // Go to End is shown at most once, and only by a give-up or the
        // terminal it was transferred to.
        let shown = effects.filter { $0 == .showGoToEnd }.count
        #expect(shown <= 1, "Go to End shown twice", sourceLocation: sourceLocation)
        if shown == 1 {
            switch event {
            case .recoveryFinished(_, .giveUp, _), .followFinished, .followCancelledByGesture:
                break
            case .endDerealized, .endRealized, .followRequested, .followDue, .explicitClaim, .recoveryStep,
                 .recoveryPagedUp, .recoveryFinished, .viewDisappeared:
                Issue.record("Go to End shown by \(event)", sourceLocation: sourceLocation)
            }
        }
        // Budget identity (invariant 6): the reducer keeps no count; the one
        // outcome recorded is the terminal's own, once, by a current terminal.
        let outcomes = effects.compactMap { effect -> (Lifecycle.RecoveryTerminal, Int)? in
            if case .recordRecoveryOutcome(let terminal, let corrections) = effect { return (terminal, corrections) }
            return nil
        }
        if case .recoveryFinished(let token, let terminal, let corrections) = event, before.currentRecovery == token {
            if corrections > 0 {
                #expect(outcomes.count == 1, "outcome not recorded exactly once", sourceLocation: sourceLocation)
                #expect(outcomes.first?.0 == terminal, "outcome recorded a different terminal", sourceLocation: sourceLocation)
                #expect(outcomes.first?.1 == corrections, "outcome recorded a different count", sourceLocation: sourceLocation)
            } else {
                #expect(outcomes.isEmpty, "outcome recorded for a recovery that corrected nothing", sourceLocation: sourceLocation)
            }
        } else {
            #expect(outcomes.isEmpty, "outcome recorded outside a current recovery terminal", sourceLocation: sourceLocation)
        }
        // Budget continuity (invariant 6): demoting an owning recovery and
        // restoring it keep the same token and start no recovery task; only
        // the executed-over-unrealized-end re-arm may start one.
        if case .followRequested = event, case .recovery(let recovery) = before.owner, followOwner(of: after) != nil {
            #expect(after.armedRecovery == .demoted(recovery), "demotion changed the recovery token", sourceLocation: sourceLocation)
            #expect(!effects.contains(where: isStartRecovery), "demotion started a recovery task", sourceLocation: sourceLocation)
        }
        if case .followFinished(let follow, _) = event, followOwner(of: before) == follow,
           case .demoted(let recovery) = before.armedRecovery {
            #expect(after.owner == .recovery(recovery), "restoration changed the recovery token", sourceLocation: sourceLocation)
            #expect(after.armedRecovery == nil, "restored recovery still armed", sourceLocation: sourceLocation)
            #expect(!effects.contains(where: isStartRecovery), "restoration started a recovery task", sourceLocation: sourceLocation)
        }
        if effects.contains(where: isStartRecovery) {
            switch event {
            case .followFinished(_, .executed):
                #expect(!before.isEndRealized, "re-arm over a realized end", sourceLocation: sourceLocation)
                #expect(before.currentRecovery == nil, "re-arm alongside a live recovery", sourceLocation: sourceLocation)
            case .endDerealized:
                break
            case .endRealized, .followRequested, .followDue, .followFinished, .followCancelledByGesture, .explicitClaim,
                 .recoveryStep, .recoveryPagedUp, .recoveryFinished, .viewDisappeared:
                Issue.record("recovery task started by \(event)", sourceLocation: sourceLocation)
            }
        }
    }

    private func isStartRecovery(_ effect: Effect) -> Bool {
        if case .startRecoveryTask = effect { return true }
        return false
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
        armed: Lifecycle.ArmedRecovery? = nil,
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
        #expect(s.armedRecovery == .polling(r1))
        #expect(s.owner == .idle)
        #expect(!s.isFollowing)
        // A recovery already polling keeps its budget.
        #expect(step(&s, .endDerealized).isEmpty)
        #expect(s.armedRecovery == .polling(r1))
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
        #expect(s.armedRecovery == .polling(RecoveryToken(id: 3)))
        #expect(s.isFollowing)
    }

    @Test func endRealizedReplaysOnlyWhenScrolledAway() {
        var s = state(armed: .polling(r1))
        #expect(step(&s, .endRealized(userIsScrolledAway: false)).isEmpty)
        #expect(s.isEndRealized)
        #expect(s.armedRecovery == .polling(r1))
        s.isEndRealized = false
        #expect(step(&s, .endRealized(userIsScrolledAway: true)) == [.replayLiveEdge(isInteracting: nil)])
        #expect(s.isEndRealized)
        #expect(s.armedRecovery == .polling(r1))
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
        var s = state(owner: .follow(f1, forced: true), armed: .polling(r2))
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
        #expect(s.armedRecovery == .demoted(r1))
        #expect(s.currentRecovery == r1)
    }

    @Test func followRequestedKeepsAnArmedRecovery() {
        var s = state(armed: .polling(r1))
        step(&s, .followRequested(forced: true))
        #expect(s.armedRecovery == .polling(r1))
        #expect(s.owner == .follow(FollowToken(id: 3), forced: true))
    }

    @Test func aReplacingFollowKeepsTheDemotedRecoveryForItsOwnDrain() {
        var s = state(owner: .follow(f1, forced: false), armed: .demoted(r2))
        let replacement = FollowToken(id: 3)
        step(&s, .followRequested(forced: true))
        #expect(s.owner == .follow(replacement, forced: true))
        #expect(s.armedRecovery == .demoted(r2))
        #expect(step(&s, .followFinished(f1, .replaced)).isEmpty)
        #expect(s.armedRecovery == .demoted(r2))
        #expect(step(&s, .followFinished(replacement, .cancelled)).isEmpty)
        #expect(s.owner == .recovery(r2))
        #expect(s.armedRecovery == nil)
    }

    // MARK: - followDue

    @Test(arguments: [false, true]) func followDueThatExecutesScrollsToEnd(forced: Bool) {
        var s = state(owner: .follow(f1, forced: forced), armed: .polling(r2))
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
        #expect(s.armedRecovery == .polling(RecoveryToken(id: 3)))
        #expect(s.owner == .idle)
    }

    @Test func executedFollowDoesNotDoubleArmARecoveryAlreadyPolling() {
        var s = state(owner: .follow(f1, forced: false), armed: .polling(r2), realized: false)
        #expect(step(&s, .followFinished(f1, .executed(nil))) == [.replayLiveEdge(isInteracting: nil)])
        #expect(s.armedRecovery == .polling(r2))
        #expect(s.nextTokenId == 3)
    }

    @Test func executedFollowOverAnUnrealizedEndRestoresADemotedRecoveryInsteadOfReArming() {
        var s = state(owner: .follow(f1, forced: false), armed: .demoted(r2), realized: false)
        #expect(step(&s, .followFinished(f1, .executed(.giveUp))) == [.replayLiveEdge(isInteracting: nil)])
        #expect(s.owner == .recovery(r2))
        #expect(s.armedRecovery == nil)
        #expect(s.nextTokenId == 3)
    }

    /// The verifier's repro of the shipped view's order at a drain: a
    /// message appended mid-correction requests an automatic follow whose
    /// debounce (100 ms) elapses before the page up settles (150 ms) and is
    /// dropped on the paged-up distance; the view keeps
    /// `isRecoveringUnrealizedEnd` raised, so the drain's replayed edge sees
    /// `isFollowing` and the page-up check then follows back.
    @Test func aDrainedFollowRestoresTheRecoveryItDemoted() {
        var s = State()
        step(&s, .endDerealized)
        #expect(nonLog(step(&s, .recoveryStep(r1, .recover(pageOffsetY: 120)))) == [.pageUp(offsetY: 120)])
        #expect(s.owner == .recovery(r1))
        #expect(step(&s, .followRequested(forced: false)) == [.startFollowTask(f2, forced: false)])
        #expect(s.owner == .follow(f2, forced: false))
        #expect(s.armedRecovery == .demoted(r1))
        #expect(s.isFollowing)
        #expect(step(&s, .followDue(f2, execute: false)).isEmpty)
        // The drain replays the swallowed edge with the recovery owning
        // again: `isFollowing` still reads true for that replay, no re-arm.
        #expect(step(&s, .followFinished(f2, .dropped)) == [.replayLiveEdge(isInteracting: nil)])
        #expect(s.owner == .recovery(r1))
        #expect(s.armedRecovery == nil)
        #expect(s.isFollowing)
        #expect(s.currentRecovery == r1)
        // Then the settled page up is granted its follow back.
        #expect(step(&s, .recoveryPagedUp(r1, mayFollowBack: true)) == [.scrollToEnd])
        #expect(s.owner == .recovery(r1))
        #expect(step(&s, .recoveryFinished(r1, .notNeeded, corrections: 1)) == [
            .recordRecoveryOutcome(.notNeeded, corrections: 1), .replayLiveEdge(isInteracting: nil),
        ])
        #expect(s.owner == .idle)
        #expect(!s.isFollowing)
    }

    /// Correcting recovery → follow → drain → geometry edge: the geometry
    /// paths read `isFollowing` from the restored owner until the recovery's
    /// own terminal, where a never-claimed polling recovery leaves it false.
    @Test func aRestoredRecoveryKeepsIsFollowingForTheGeometryEdgeUntilItsTerminal() {
        var corrected = State()
        step(&corrected, .endDerealized)
        step(&corrected, .recoveryStep(r1, .followToEnd))
        step(&corrected, .followRequested(forced: true))
        step(&corrected, .followDue(f2, execute: false))
        #expect(step(&corrected, .followFinished(f2, .yielded)).isEmpty)
        #expect(corrected.owner == .recovery(r1))
        #expect(corrected.isFollowing)
        #expect(step(&corrected, .endRealized(userIsScrolledAway: true)) == [.replayLiveEdge(isInteracting: nil)])
        #expect(corrected.isFollowing)
        #expect(step(&corrected, .recoveryFinished(r1, .notNeeded, corrections: 1)) == [
            .recordRecoveryOutcome(.notNeeded, corrections: 1), .replayLiveEdge(isInteracting: nil),
        ])
        #expect(!corrected.isFollowing)

        var polling = State()
        step(&polling, .endDerealized)
        step(&polling, .followRequested(forced: true))
        step(&polling, .followDue(f2, execute: false))
        #expect(step(&polling, .followFinished(f2, .yielded)).isEmpty)
        #expect(polling.owner == .idle)
        #expect(polling.armedRecovery == .polling(r1))
        #expect(!polling.isFollowing)
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
        var s = state(owner: .follow(f1, forced: false), armed: .polling(r2), realized: false)
        #expect(step(&s, .followFinished(f1, .dropped)) == [.replayLiveEdge(isInteracting: nil)])
        #expect(s.armedRecovery == .polling(r2))
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

    @Test(arguments: [
        ConversationTranscriptRecoveryLifecycle.ArmedRecovery.polling(ConversationTranscriptRecoveryLifecycle.RecoveryToken(id: 2)),
        .demoted(ConversationTranscriptRecoveryLifecycle.RecoveryToken(id: 2)),
    ]) func gestureCancelsTheFollowAndTheArmedRecoveryTogether(armed: ConversationTranscriptRecoveryLifecycle.ArmedRecovery) {
        var s = state(owner: .follow(f1, forced: true), armed: armed, realized: false)
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
        var s = state(owner: .follow(f1, forced: false), armed: .polling(r2), fallback: .transferred(to: f1), realized: false)
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
        var armedUnderFollow = state(owner: .follow(f1, forced: true), armed: .polling(r2), fallback: .transferred(to: f1))
        #expect(step(&armedUnderFollow, event) == [.cancelRecoveryTask(r2)])
        #expect(armedUnderFollow.owner == .follow(f1, forced: true))
        #expect(armedUnderFollow.fallback == .transferred(to: f1))
        #expect(armedUnderFollow.armedRecovery == nil)

        // A demoted recovery is cancelled too: the follow's drain restores
        // nothing.
        var demotedUnderFollow = state(owner: .follow(f1, forced: false), armed: .demoted(r2))
        #expect(step(&demotedUnderFollow, event) == [.cancelRecoveryTask(r2)])
        #expect(demotedUnderFollow.owner == .follow(f1, forced: false))
        #expect(demotedUnderFollow.armedRecovery == nil)
        #expect(step(&demotedUnderFollow, .followFinished(f1, .dropped)) == [.replayLiveEdge(isInteracting: nil)])
        #expect(demotedUnderFollow.owner == .idle)

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
        var armed = state(armed: .polling(r1))
        let before = armed
        #expect(step(&armed, .recoveryStep(r1, .settling)).isEmpty)
        #expect(armed == before)
        var owning = state(owner: .recovery(r1))
        #expect(step(&owning, .recoveryStep(r1, .settling)).isEmpty)
        #expect(owning.owner == .recovery(r1))
    }

    @Test func followToEndCorrectionClaimsTheViewport() {
        var s = state(armed: .polling(r1))
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
        var s = state(armed: .polling(r1))
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
            for armed in [Lifecycle.ArmedRecovery.polling(r2), .demoted(r2)] {
                var s = state(owner: .follow(f1, forced: false), armed: armed)
                let before = s
                #expect(step(&s, .recoveryStep(r2, continuation)).isEmpty)
                #expect(s == before)
            }
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
        var demoted = state(owner: .follow(f1, forced: true), armed: .demoted(r2))
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

    @Test(arguments: [
        ConversationTranscriptRecoveryLifecycle.ArmedRecovery.polling(ConversationTranscriptRecoveryLifecycle.RecoveryToken(id: 2)),
        .demoted(ConversationTranscriptRecoveryLifecycle.RecoveryToken(id: 2)),
    ]) func giveUpUnderAFollowTransfersToThatFollow(armed: ConversationTranscriptRecoveryLifecycle.ArmedRecovery) {
        var s = state(owner: .follow(f1, forced: false), armed: armed, realized: false)
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
        for armed in [Lifecycle.ArmedRecovery.polling(r2), .demoted(r2)] {
            var underFollow = state(owner: .follow(f1, forced: true), armed: armed)
            #expect(step(&underFollow, .recoveryFinished(r2, terminal, corrections: 0)) == [.replayLiveEdge(isInteracting: nil)])
            #expect(underFollow.owner == .follow(f1, forced: true))
            #expect(underFollow.armedRecovery == nil)
        }
    }

    @Test func aRecoveryThatCorrectedNothingRecordsNoOutcome() {
        var s = state(armed: .polling(r1), realized: true)
        #expect(step(&s, .recoveryFinished(r1, .notNeeded, corrections: 0)) == [.replayLiveEdge(isInteracting: nil)])
        #expect(s.armedRecovery == nil)
    }

    // MARK: - Identity

    @Test func staleTokensChangeNothing() {
        let states = [
            State(),
            state(owner: .follow(f1, forced: true), armed: .polling(r2), fallback: .transferred(to: f1)),
            state(owner: .follow(f1, forced: false), armed: .demoted(r2)),
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
    /// terminal events can meet. `f1` is the follow, `r2` the recovery. A
    /// demoted recovery exists only under a follow, and never with a
    /// transfer: a transfer names the follow that owns, while a demotion is
    /// made over an owning recovery.
    private var terminalStates: [State] {
        var states: [State] = []
        for realized in [false, true] {
            for armed in [nil, Lifecycle.ArmedRecovery.polling(r2)] {
                states.append(state(owner: .idle, armed: armed, realized: realized))
                for forced in [false, true] {
                    for fallback in [Lifecycle.GiveUpFallback.none, .transferred(to: f1)] {
                        states.append(state(owner: .follow(f1, forced: forced), armed: armed, fallback: fallback, realized: realized))
                    }
                }
            }
            for forced in [false, true] {
                states.append(state(owner: .follow(f1, forced: forced), armed: .demoted(r2), realized: realized))
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
        #expect(cases == 26 * 3 * 2 * 2)
    }

    /// Every terminal state, including the recovery-owner ones where any
    /// follow token is stale.
    @Test func followFinishedTable() {
        let terminals: [Lifecycle.FollowTerminal] = [
            .executed(nil), .executed(.landed), .dropped, .yielded, .cancelled, .replaced,
        ]
        var cases = 0
        for original in terminalStates {
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
                    if case .demoted(let recovery) = original.armedRecovery {
                        expected.owner = .recovery(recovery)
                        expected.armedRecovery = nil
                    }
                    let transferred = original.fallback == .transferred(to: token)
                    expected.fallback = .none
                    switch terminal {
                    case .executed:
                        if !forced { expectedEffects.append(.replayLiveEdge(isInteracting: nil)) }
                        if !original.isEndRealized, original.armedRecovery == nil {
                            let armed = RecoveryToken(id: original.nextTokenId)
                            expected.armedRecovery = .polling(armed)
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
        #expect(cases == 26 * 6 * 2)
    }

    // MARK: - Sequences

    private typealias Geometry = ConversationTranscriptScrollPolicy.ViewportGeometry
    private typealias RecoveryStep = ConversationTranscriptScrollPolicy.UnrealizedEndRecoveryStep

    /// The reducer's log lines, so a sequence asserts each transition's
    /// full ordered effect list.
    private enum Log {
        static let followToEnd = Effect.log("[SCROLL] End row off screen short of the bottom; following to the end")
        static let pageUp = Effect.log("[SCROLL] Blank viewport at the bottom; paging up and following back")
        static let recoveryYielded = Effect.log("[SCROLL] End recovery yielded the paged-up viewport to the user")
        static let gaveUp = Effect.log("[SCROLL] End recovery gave up over an unrealized end row; showing Go to End")
        static let deferredGaveUp = Effect.log(
            "[SCROLL] End recovery gave up and the follow it deferred to did not execute; showing Go to End")
        static let forcedYielded = Effect.log("[SCROLL] Forced follow yielded to the user's gesture")
        static let forcedCancelled = Effect.log("[SCROLL] Forced follow cancelled: the user took over")
    }

    /// Drives the reducer the way the view does, with its asynchrony
    /// replaced by explicit events and its effects executed against
    /// scripted geometry. The live tasks are the token sets the start /
    /// cancel effects maintain (a terminal for a current token ends its
    /// task); `replayLiveEdge` and a raw `geometryEdge` apply
    /// `scrolledAwayTransition` and `shouldRePinAfterContentGrowth` to the
    /// harness's `userIsScrolledAway`, counting growth re-pins; `showGoToEnd`
    /// raises the flag; a recorded outcome is rendered through
    /// `unrealizedEndRecoverySummary` as the demo-data report does; the
    /// recovery loop's polls go through `unrealizedEndRecoveryStep` against
    /// the live state. No clock: the sequence is the schedule. Every
    /// transition is checked against the contract's invariants.
    private struct LifecycleHarness {
        static let threshold: CGFloat = 50
        var state: State
        var userIsScrolledAway: Bool
        var distanceToBottom: CGFloat = 0
        var isInteracting = false
        var hasInitiallyScrolled = true
        var liveFollows: Set<FollowToken> = []
        var liveRecoveries: Set<RecoveryToken> = []
        var scrolls = 0
        var pageUps: [CGFloat] = []
        var rePins = 0
        var goToEndShown = 0
        var outcomes: [Effect] = []
        var summaries: [String?] = []
        let check: (State, Event, State, [Effect], SourceLocation) -> Void

        var followOwns: Bool {
            if case .follow = state.owner { return true }
            return false
        }

        func isLive(_ token: FollowToken) -> Bool { liveFollows.contains(token) }
        func isLive(_ token: RecoveryToken) -> Bool { liveRecoveries.contains(token) }

        @discardableResult
        mutating func send(_ event: Event, sourceLocation: SourceLocation = #_sourceLocation) -> [Effect] {
            let before = state
            let (after, effects) = Lifecycle.transition(before, event)
            check(before, event, after, effects, sourceLocation)
            state = after
            if case .followFinished(let token, _) = event, case .follow(token, _) = before.owner {
                liveFollows.remove(token)
            }
            if case .recoveryFinished(let token, _, _) = event, before.currentRecovery == token {
                liveRecoveries.remove(token)
            }
            for effect in effects {
                switch effect {
                case .startFollowTask(let token, _): liveFollows.insert(token)
                case .cancelFollowTask(let token): liveFollows.remove(token)
                case .startRecoveryTask(let token): liveRecoveries.insert(token)
                case .cancelRecoveryTask(let token): liveRecoveries.remove(token)
                case .scrollToEnd: scrolls += 1
                case .pageUp(let offsetY): pageUps.append(offsetY)
                case .replayLiveEdge(let sample): applyEdge(isInteracting: sample ?? isInteracting)
                case .showGoToEnd:
                    userIsScrolledAway = true
                    goToEndShown += 1
                case .recordRecoveryOutcome(let terminal, let corrections):
                    outcomes.append(effect)
                    summaries.append(ConversationTranscriptScrollPolicy.unrealizedEndRecoverySummary(
                        outcome: terminal, corrections: corrections))
                case .log: break
                }
            }
            return effects
        }

        /// A geometry edge from the scroll view: a layout settle, a content
        /// update, a gesture sample or its phase ending.
        mutating func geometryEdge(distanceToBottom: CGFloat, isInteracting sample: Bool? = nil) {
            self.distanceToBottom = distanceToBottom
            applyEdge(isInteracting: sample ?? isInteracting)
        }

        private mutating func applyEdge(isInteracting: Bool) {
            let geometryAway = ConversationTranscriptScrollPolicy.isScrolledAway(
                distanceToBottom: distanceToBottom, atBottomThreshold: Self.threshold)
            let next = ConversationTranscriptScrollPolicy.scrolledAwayTransition(
                current: userIsScrolledAway,
                geometryAway: geometryAway,
                isInteracting: isInteracting,
                isEndRealized: state.isEndRealized)
            userIsScrolledAway = next
            if ConversationTranscriptScrollPolicy.shouldRePinAfterContentGrowth(
                geometryAway: geometryAway,
                isInteracting: isInteracting,
                isFollowing: state.isFollowing,
                hasInitiallyScrolled: hasInitiallyScrolled,
                userIsScrolledAway: next
            ) {
                rePins += 1
            }
        }

        /// The finger lands: the takeover the view sends, then the gesture's
        /// own edge.
        @discardableResult
        mutating func gestureBegins(
            distanceToBottom: CGFloat, sourceLocation: SourceLocation = #_sourceLocation
        ) -> [Effect] {
            isInteracting = true
            var effects: [Effect] = []
            if ConversationTranscriptScrollPolicy.gestureTakesOverPendingFollow(
                isInteracting: true, isFollowing: state.isFollowing
            ) {
                effects = send(.followCancelledByGesture, sourceLocation: sourceLocation)
            }
            geometryEdge(distanceToBottom: distanceToBottom)
            return effects
        }

        /// Go to End: the flag cleared, the recovery claimed (cancelling
        /// `cancelling`, asserted as its own transition), a forced follow
        /// whose request effects are returned.
        @discardableResult
        mutating func tapGoToEnd(
            cancelling recovery: RecoveryToken? = nil, sourceLocation: SourceLocation = #_sourceLocation
        ) -> [Effect] {
            userIsScrolledAway = false
            let claim: [Effect] = recovery.map { [.cancelRecoveryTask($0)] } ?? []
            #expect(send(.explicitClaim, sourceLocation: sourceLocation) == claim, sourceLocation: sourceLocation)
            return send(.followRequested(forced: true), sourceLocation: sourceLocation)
        }

        /// `shouldExecuteFollow` for the pending follow against the live
        /// distance and gesture.
        func execute() -> Bool {
            guard case .follow(_, let forced) = state.owner else { return false }
            return ConversationTranscriptScrollPolicy.shouldExecuteFollow(
                forced: forced,
                userIsScrolledAway: userIsScrolledAway,
                distanceToBottom: distanceToBottom,
                isInteracting: isInteracting,
                driftTolerance: 1,
                atBottomThreshold: Self.threshold)
        }

        /// The page-up check, reading a follow pending as the view does.
        func mayFollowBack() -> Bool {
            ConversationTranscriptScrollPolicy.unrealizedEndRecoveryMayFollowBack(
                isInteracting: isInteracting,
                userIsScrolledAway: userIsScrolledAway,
                isFollowing: followOwns)
        }

        /// One poll of the recovery loop at rest on `geometry`.
        func poll(
            _ geometry: Geometry, correctionsLeft: Int = 2, correctionsSpent: Int = 0, timedOut: Bool = false
        ) -> RecoveryStep {
            ConversationTranscriptScrollPolicy.unrealizedEndRecoveryStep(
                geometry: geometry,
                previous: geometry,
                isEndRealized: state.isEndRealized,
                isInteracting: isInteracting,
                isFollowing: followOwns,
                hasInitiallyScrolled: hasInitiallyScrolled,
                userIsScrolledAway: userIsScrolledAway,
                correctionsLeft: correctionsLeft,
                correctionsSpent: correctionsSpent,
                timedOut: timedOut,
                atBottomThreshold: Self.threshold)
        }
    }

    private let f3 = FollowToken(id: 3)
    private let r3 = RecoveryToken(id: 3)
    private let r4 = RecoveryToken(id: 4)

    /// A pinned transcript at rest at the bottom, its end row realized.
    private func harness(realized: Bool = true, scrolledAway: Bool = false) -> LifecycleHarness {
        LifecycleHarness(state: State(isEndRealized: realized), userIsScrolledAway: scrolledAway, check: checkInvariants)
    }

    /// Content 1 000 in a 700 container: offset 300 is the bottom, 260 is
    /// 40 short (inside the band), 180 is 120 short.
    private func geometry(offsetY: CGFloat, contentHeight: CGFloat = 1_000) -> Geometry {
        Geometry(contentOffsetY: offsetY, contentHeight: contentHeight, containerHeight: 700, topInset: 0, bottomInset: 0)
    }

    /// A viewport the geometry calls the bottom over a blank lazy stack.
    private var blank: Geometry { geometry(offsetY: 2_300, contentHeight: 3_000) }

    /// Scenario 1 (14927b8): a correction pages up and the finger lands
    /// during the settle. The takeover cancels the recovery; the settle's
    /// continuation and terminal are stale, granted or not, so nothing
    /// scrolls the user back and the recovery shows no Go to End — the flag
    /// raised is the gesture's own edge.
    @Test func aPageUpTakenOverByAGestureDuringTheSettleIsStale() {
        var h = harness()
        #expect(h.send(.endDerealized) == [.startRecoveryTask(r1)])
        #expect(h.isLive(r1))
        #expect(h.poll(blank) == .continue(.recover(pageOffsetY: 1_600)))
        #expect(h.send(.recoveryStep(r1, .recover(pageOffsetY: 1_600))) == [Log.pageUp, .pageUp(offsetY: 1_600)])
        #expect(h.state.owner == .recovery(r1))
        #expect(h.pageUps == [1_600])
        #expect(h.gestureBegins(distanceToBottom: 700) == [.cancelRecoveryTask(r1)])
        #expect(h.state.owner == .idle)
        #expect(h.state.currentRecovery == nil)
        #expect(!h.isLive(r1))
        #expect(h.userIsScrolledAway)
        #expect(h.goToEndShown == 0)
        #expect(!h.mayFollowBack())
        #expect(h.send(.recoveryPagedUp(r1, mayFollowBack: false)).isEmpty)
        #expect(h.send(.recoveryPagedUp(r1, mayFollowBack: true)).isEmpty)
        #expect(h.send(.recoveryFinished(r1, .yieldToUser, corrections: 1)).isEmpty)
        #expect(h.scrolls == 0)
        #expect(h.rePins == 0)
        #expect(h.outcomes.isEmpty)
        #expect(h.goToEndShown == 0)
        #expect(h.state.owner == .idle)
    }

    /// Scenario 2 (e3cd988): a message appended mid-correction requests an
    /// automatic follow; the recovery's budget is spent under it, so the
    /// give-up is transferred to that follow; content grows during the
    /// debounce and the follow comes due 120pt short with no gesture —
    /// dropped. Its drain shows Go to End over the still-unrealized row,
    /// re-pins nothing over the button and arms nothing; the transfer is
    /// discharged exactly once. Without the transfer the drain would have
    /// replayed the edge as a raw re-pin with the button hidden.
    @Test func aGiveUpUnderAPendingAutomaticFollowIsShownWhenThatFollowIsDropped() {
        var h = harness()
        #expect(h.send(.endDerealized) == [.startRecoveryTask(r1)])
        #expect(h.poll(geometry(offsetY: 260)) == .continue(.followToEnd))
        #expect(h.send(.recoveryStep(r1, .followToEnd)) == [Log.followToEnd, .scrollToEnd])
        #expect(h.scrolls == 1)
        #expect(h.send(.followRequested(forced: false)) == [.startFollowTask(f2, forced: false)])
        #expect(h.state.owner == .follow(f2, forced: false))
        #expect(h.state.armedRecovery == .demoted(r1))
        #expect(h.poll(geometry(offsetY: 260), correctionsSpent: 1) == .continue(.settling))
        #expect(h.send(.recoveryStep(r1, .settling)).isEmpty)
        #expect(h.poll(geometry(offsetY: 260), correctionsSpent: 1, timedOut: true) == .finish(.giveUp))
        h.distanceToBottom = 40
        #expect(h.send(.recoveryFinished(r1, .giveUp, corrections: 1)) == [
            .recordRecoveryOutcome(.giveUp, corrections: 1), .replayLiveEdge(isInteracting: nil),
        ])
        #expect(h.state.fallback == .transferred(to: f2))
        #expect(h.state.armedRecovery == nil)
        #expect(h.state.owner == .follow(f2, forced: false))
        #expect(!h.isLive(r1))
        #expect(h.isLive(f2))
        #expect(!h.userIsScrolledAway)
        #expect(h.rePins == 0)
        h.distanceToBottom = 120
        #expect(!h.execute())
        #expect(h.send(.followDue(f2, execute: false)).isEmpty)
        #expect(h.send(.followFinished(f2, .dropped)) == [Log.deferredGaveUp, .showGoToEnd])
        #expect(h.state.fallback == .none)
        #expect(h.state.owner == .idle)
        #expect(h.state.currentRecovery == nil)
        #expect(!h.isLive(f2))
        #expect(h.userIsScrolledAway)
        #expect(h.goToEndShown == 1)
        #expect(h.rePins == 0)
        #expect(h.scrolls == 1)
        #expect(h.send(.followFinished(f2, .dropped)).isEmpty)
        #expect(h.goToEndShown == 1)
    }

    /// A recovery polling under a follow requested meanwhile times out over
    /// the blank: the give-up is transferred to that follow.
    private func transferredGiveUp(forced: Bool) -> LifecycleHarness {
        var h = harness()
        #expect(h.send(.endDerealized) == [.startRecoveryTask(r1)])
        #expect(h.send(.followRequested(forced: forced)) == [.startFollowTask(f2, forced: forced)])
        #expect(h.state.armedRecovery == .polling(r1))
        #expect(h.poll(geometry(offsetY: 300)) == .continue(.settling))
        #expect(h.send(.recoveryStep(r1, .settling)).isEmpty)
        #expect(h.poll(geometry(offsetY: 300), timedOut: true) == .finish(.giveUp))
        #expect(h.send(.recoveryFinished(r1, .giveUp, corrections: 0)) == [.replayLiveEdge(isInteracting: nil)])
        #expect(h.state.fallback == .transferred(to: f2))
        #expect(h.state.armedRecovery == nil)
        #expect(h.outcomes.isEmpty)
        #expect(!h.userIsScrolledAway)
        return h
    }

    /// Migrated from `deferredGiveUpShowsGoToEndWhenTheFollowIsDropped`
    /// (the executed half): a follow that executed clears the transfer and
    /// re-arms the recovery instead of showing Go to End — automatic (no
    /// landing) or forced, whatever its landing. Without a transfer, a
    /// dropped automatic follow's drain is the raw edge replay.
    @Test func aTransferredGiveUpIsClearedByAnyExecutedDrainWhichReArmsTheRecovery() {
        var automatic = transferredGiveUp(forced: false)
        #expect(automatic.execute())
        #expect(automatic.send(.followDue(f2, execute: true)) == [.scrollToEnd])
        #expect(automatic.send(.followFinished(f2, .executed(nil))) == [
            .replayLiveEdge(isInteracting: nil), .startRecoveryTask(r3),
        ])
        #expect(automatic.state.fallback == .none)
        #expect(automatic.state.owner == .idle)
        #expect(automatic.state.armedRecovery == .polling(r3))
        #expect(automatic.isLive(r3))
        #expect(automatic.goToEndShown == 0)
        #expect(!automatic.userIsScrolledAway)

        for landing in [ConversationTranscriptScrollPolicy.FollowLandingTerminal.landed, .giveUp, .yieldToUser] {
            var forced = transferredGiveUp(forced: true)
            #expect(forced.execute())
            #expect(forced.send(.followDue(f2, execute: true)) == [.scrollToEnd])
            #expect(forced.send(.followFinished(f2, .executed(landing))) == [.startRecoveryTask(r3)])
            #expect(forced.state.fallback == .none)
            #expect(forced.state.armedRecovery == .polling(r3))
            #expect(forced.goToEndShown == 0)
            #expect(!forced.userIsScrolledAway)
        }

        var plain = harness()
        #expect(plain.send(.followRequested(forced: false)) == [.startFollowTask(f1, forced: false)])
        plain.distanceToBottom = 120
        #expect(!plain.execute())
        #expect(plain.send(.followDue(f1, execute: false)).isEmpty)
        #expect(plain.send(.followFinished(f1, .dropped)) == [.replayLiveEdge(isInteracting: nil)])
        #expect(plain.state.fallback == .none)
        #expect(plain.goToEndShown == 0)
        #expect(!plain.userIsScrolledAway)
        #expect(plain.rePins == 1)
    }

    /// Scenario 3 (7e0ecbc): the transferred give-up does not depend on the
    /// follow executing. A forced follow yielding to the finger and an
    /// automatic one a gesture cancels each show Go to End once; a follow a
    /// newer request replaces hands the transfer to the replacing token —
    /// today's `scrollDebounceTask?.cancel()` in `scrollToBottom` resolves
    /// no deferral, so it survives to the replacing follow's drain, which
    /// re-arms the recovery if it executed and shows Go to End if it did
    /// not. The replaced and cancelled tasks' own terminals are stale.
    @Test func aTransferredGiveUpIsDischargedOnceByYieldCancelOrReplace() {
        var yielded = transferredGiveUp(forced: true)
        yielded.isInteracting = true
        #expect(!yielded.execute())
        #expect(yielded.send(.followDue(f2, execute: false)) == [Log.forcedYielded, .replayLiveEdge(isInteracting: true)])
        #expect(!yielded.userIsScrolledAway)
        #expect(yielded.send(.followFinished(f2, .yielded)) == [Log.deferredGaveUp, .showGoToEnd])
        #expect(yielded.state.fallback == .none)
        #expect(yielded.state.owner == .idle)
        #expect(yielded.userIsScrolledAway)
        #expect(yielded.goToEndShown == 1)
        #expect(yielded.send(.followFinished(f2, .yielded)).isEmpty)
        #expect(yielded.goToEndShown == 1)

        var cancelled = transferredGiveUp(forced: false)
        #expect(cancelled.gestureBegins(distanceToBottom: 200) == [
            .cancelFollowTask(f2), Log.deferredGaveUp, .showGoToEnd,
        ])
        #expect(cancelled.state.fallback == .none)
        #expect(cancelled.state.owner == .idle)
        #expect(!cancelled.isLive(f2))
        #expect(cancelled.goToEndShown == 1)
        #expect(cancelled.send(.followFinished(f2, .cancelled)).isEmpty)
        #expect(cancelled.goToEndShown == 1)
        #expect(cancelled.scrolls == 0)

        var replaced = transferredGiveUp(forced: false)
        #expect(replaced.send(.explicitClaim).isEmpty)
        #expect(replaced.send(.followRequested(forced: true)) == [
            .cancelFollowTask(f2), .startFollowTask(f3, forced: true),
        ])
        #expect(replaced.state.fallback == .transferred(to: f3))
        #expect(!replaced.isLive(f2))
        #expect(replaced.isLive(f3))
        #expect(replaced.send(.followFinished(f2, .replaced)).isEmpty)
        #expect(replaced.state.fallback == .transferred(to: f3))
        #expect(replaced.goToEndShown == 0)
        var replacementYielded = replaced
        #expect(replaced.execute())
        #expect(replaced.send(.followDue(f3, execute: true)) == [.scrollToEnd])
        #expect(replaced.send(.followFinished(f3, .executed(.landed))) == [.startRecoveryTask(r4)])
        #expect(replaced.state.fallback == .none)
        #expect(replaced.state.armedRecovery == .polling(r4))
        #expect(replaced.goToEndShown == 0)
        #expect(!replaced.userIsScrolledAway)
        replacementYielded.isInteracting = true
        #expect(!replacementYielded.execute())
        #expect(replacementYielded.send(.followDue(f3, execute: false)) == [
            Log.forcedYielded, .replayLiveEdge(isInteracting: true),
        ])
        #expect(replacementYielded.send(.followFinished(f3, .yielded)) == [Log.deferredGaveUp, .showGoToEnd])
        #expect(replacementYielded.state.fallback == .none)
        #expect(replacementYielded.state.currentRecovery == nil)
        #expect(replacementYielded.goToEndShown == 1)
    }

    /// The transfer over an end row that realized before the follow drained
    /// clears silently: the dropped follow's replayed edge re-pins the
    /// viewport to the realized row by the growth path.
    @Test func aTransferOverAnEndRowThatRealizedMeanwhileClearsSilently() {
        var h = transferredGiveUp(forced: false)
        #expect(h.send(.endRealized(userIsScrolledAway: false)).isEmpty)
        h.distanceToBottom = 120
        #expect(!h.execute())
        #expect(h.send(.followDue(f2, execute: false)).isEmpty)
        #expect(h.send(.followFinished(f2, .dropped)) == [.replayLiveEdge(isInteracting: nil)])
        #expect(h.state.fallback == .none)
        #expect(h.goToEndShown == 0)
        #expect(!h.userIsScrolledAway)
        #expect(h.rePins == 1)
    }

    /// Scenario 4 (b0c0941; migrated from
    /// `followDrainingOverAnUnrealizedEndRowArmsTheRecovery`): Go to End
    /// over a blank with nothing armed. The tap's forced follow executes and
    /// drains with the end row still unrealized, so the recovery is
    /// re-armed from the level — whatever the landing reported — and judges
    /// the blank from geometry; an automatic follow (the user's message)
    /// that executed re-arms it the same way; a follow that yielded or was
    /// dropped landed nowhere and arms nothing; a realized end row needs
    /// nothing either way.
    @Test func aFollowDrainingOverAnAlreadyUnrealizedEndRowReArmsTheRecovery() {
        var h = harness(realized: false, scrolledAway: true)
        #expect(h.tapGoToEnd() == [.startFollowTask(f1, forced: true)])
        #expect(!h.userIsScrolledAway)
        #expect(h.state.currentRecovery == nil)
        var yielded = h
        #expect(h.execute())
        #expect(h.send(.followDue(f1, execute: true)) == [.scrollToEnd])
        var gaveUp = h
        var realizedFirst = h
        #expect(h.send(.followFinished(f1, .executed(.landed))) == [.startRecoveryTask(r2)])
        #expect(h.state.owner == .idle)
        #expect(h.state.armedRecovery == .polling(r2))
        #expect(h.isLive(r2))
        #expect(h.poll(blank) == .continue(.recover(pageOffsetY: 1_600)))
        #expect(h.send(.endRealized(userIsScrolledAway: false)).isEmpty)
        #expect(h.poll(blank) == .finish(.notNeeded))

        #expect(gaveUp.send(.followFinished(f1, .executed(.giveUp))) == [.startRecoveryTask(r2)])
        #expect(gaveUp.state.armedRecovery == .polling(r2))

        #expect(realizedFirst.send(.endRealized(userIsScrolledAway: false)).isEmpty)
        #expect(realizedFirst.send(.followFinished(f1, .executed(.landed))).isEmpty)
        #expect(realizedFirst.state.currentRecovery == nil)

        yielded.isInteracting = true
        #expect(!yielded.execute())
        #expect(yielded.send(.followDue(f1, execute: false)) == [Log.forcedYielded, .replayLiveEdge(isInteracting: true)])
        #expect(yielded.send(.followFinished(f1, .yielded)).isEmpty)
        #expect(yielded.state.owner == .idle)
        #expect(yielded.state.currentRecovery == nil)
        #expect(yielded.scrolls == 0)

        var automatic = harness(realized: false)
        #expect(automatic.send(.followRequested(forced: false)) == [.startFollowTask(f1, forced: false)])
        var dropped = automatic
        var realizedAutomatic = automatic
        #expect(automatic.execute())
        #expect(automatic.send(.followDue(f1, execute: true)) == [.scrollToEnd])
        #expect(automatic.send(.followFinished(f1, .executed(nil))) == [
            .replayLiveEdge(isInteracting: nil), .startRecoveryTask(r2),
        ])
        #expect(automatic.state.armedRecovery == .polling(r2))
        #expect(automatic.isLive(r2))
        #expect(automatic.poll(blank) == .continue(.recover(pageOffsetY: 1_600)))

        #expect(realizedAutomatic.send(.endRealized(userIsScrolledAway: false)).isEmpty)
        #expect(realizedAutomatic.send(.followDue(f1, execute: true)) == [.scrollToEnd])
        #expect(realizedAutomatic.send(.followFinished(f1, .executed(nil))) == [.replayLiveEdge(isInteracting: nil)])
        #expect(realizedAutomatic.state.currentRecovery == nil)

        dropped.distanceToBottom = 120
        #expect(!dropped.execute())
        #expect(dropped.send(.followDue(f1, execute: false)).isEmpty)
        #expect(dropped.send(.followFinished(f1, .dropped)) == [.replayLiveEdge(isInteracting: nil)])
        #expect(dropped.state.currentRecovery == nil)
        #expect(dropped.goToEndShown == 0)

        var yieldedRealized = harness(realized: true, scrolledAway: true)
        #expect(yieldedRealized.tapGoToEnd() == [.startFollowTask(f1, forced: true)])
        yieldedRealized.isInteracting = true
        #expect(!yieldedRealized.execute())
        #expect(yieldedRealized.send(.followDue(f1, execute: false)) == [
            Log.forcedYielded, .replayLiveEdge(isInteracting: true),
        ])
        #expect(yieldedRealized.send(.followFinished(f1, .yielded)).isEmpty)
        #expect(yieldedRealized.state.currentRecovery == nil)
    }

    /// Scenario 5 (7e0ecbc, e3cd988): the recovery spends its budget over
    /// the blank and shows Go to End. A viewport over an unrealized end row
    /// reads "at bottom" while showing nothing (#338), so the blank's
    /// at-bottom edges — a layout settle, a gesture ending there, a bounce
    /// — clear nothing and re-pin nothing over the button, and its away
    /// edges are as before; a pinned viewport over the blank is kept pinned
    /// the same way. The row realizing replays the live edge, and only then
    /// does the ordinary rule apply: cleared at the bottom, growth re-pinned,
    /// a drag away scrolled away.
    @Test func anAtBottomEdgeOverTheBlankKeepsGoToEndUntilTheMarkerRealizes() {
        var h = harness()
        #expect(h.send(.endDerealized) == [.startRecoveryTask(r1)])
        #expect(h.poll(blank) == .continue(.recover(pageOffsetY: 1_600)))
        #expect(h.send(.recoveryStep(r1, .recover(pageOffsetY: 1_600))) == [Log.pageUp, .pageUp(offsetY: 1_600)])
        h.distanceToBottom = 700
        #expect(h.mayFollowBack())
        #expect(h.send(.recoveryPagedUp(r1, mayFollowBack: true)) == [.scrollToEnd])
        h.distanceToBottom = 0
        #expect(h.poll(blank, correctionsLeft: 1, correctionsSpent: 1) == .continue(.recover(pageOffsetY: 1_600)))
        #expect(h.send(.recoveryStep(r1, .recover(pageOffsetY: 1_600))) == [Log.pageUp, .pageUp(offsetY: 1_600)])
        let secondFollowBack = h.mayFollowBack()
        #expect(secondFollowBack)
        #expect(h.send(.recoveryPagedUp(r1, mayFollowBack: secondFollowBack)) == [.scrollToEnd])
        #expect(h.poll(blank, correctionsLeft: 0, correctionsSpent: 2) == .finish(.giveUp))
        #expect(h.send(.recoveryFinished(r1, .giveUp, corrections: 2)) == [
            .recordRecoveryOutcome(.giveUp, corrections: 2), Log.gaveUp, .showGoToEnd,
        ])
        #expect(h.state.owner == .idle)
        #expect(h.state.currentRecovery == nil)
        #expect(h.userIsScrolledAway)
        #expect(h.scrolls == 2)
        #expect(h.pageUps == [1_600, 1_600])

        h.geometryEdge(distanceToBottom: 0)
        #expect(h.userIsScrolledAway)
        h.geometryEdge(distanceToBottom: 40, isInteracting: true)
        #expect(h.userIsScrolledAway)
        h.geometryEdge(distanceToBottom: -30)
        #expect(h.userIsScrolledAway)
        h.geometryEdge(distanceToBottom: 120)
        #expect(h.userIsScrolledAway)
        #expect(h.rePins == 0)
        #expect(h.scrolls == 2)

        var pinned = harness()
        #expect(pinned.send(.endDerealized) == [.startRecoveryTask(r1)])
        pinned.geometryEdge(distanceToBottom: 0)
        #expect(!pinned.userIsScrolledAway)
        pinned.geometryEdge(distanceToBottom: 120)
        #expect(!pinned.userIsScrolledAway)
        pinned.geometryEdge(distanceToBottom: 120, isInteracting: true)
        #expect(pinned.userIsScrolledAway)

        h.distanceToBottom = 0
        #expect(h.send(.endRealized(userIsScrolledAway: true)) == [.replayLiveEdge(isInteracting: nil)])
        #expect(h.state.isEndRealized)
        #expect(!h.userIsScrolledAway)
        #expect(h.rePins == 0)
        #expect(h.goToEndShown == 1)
        h.geometryEdge(distanceToBottom: 120)
        #expect(!h.userIsScrolledAway)
        #expect(h.rePins == 1)
        h.geometryEdge(distanceToBottom: 120, isInteracting: true)
        #expect(h.userIsScrolledAway)
        h.geometryEdge(distanceToBottom: 40, isInteracting: true)
        #expect(!h.userIsScrolledAway)
    }

    /// Scenario 6: a completed follow's terminal replayed after a new
    /// follow was requested, and a cancelled recovery's continuations, are
    /// stale — no state change, no effect, no outcome — while the current
    /// tokens keep going.
    @Test func staleContinuationsAfterAReplacementAndAClaimChangeNothing() {
        var h = harness()
        #expect(h.send(.followRequested(forced: false)) == [.startFollowTask(f1, forced: false)])
        #expect(h.send(.followDue(f1, execute: true)) == [.scrollToEnd])
        #expect(h.send(.followFinished(f1, .executed(nil))) == [.replayLiveEdge(isInteracting: nil)])
        #expect(h.state.owner == .idle)
        #expect(!h.isLive(f1))
        #expect(h.send(.followRequested(forced: true)) == [.startFollowTask(f2, forced: true)])
        let afterRequest = h.state
        #expect(h.send(.followFinished(f1, .executed(nil))).isEmpty)
        #expect(h.send(.followDue(f1, execute: true)).isEmpty)
        #expect(h.send(.followFinished(f1, .dropped)).isEmpty)
        #expect(h.state == afterRequest)
        #expect(h.scrolls == 1)

        #expect(h.send(.endDerealized) == [.startRecoveryTask(r3)])
        #expect(h.send(.explicitClaim) == [.cancelRecoveryTask(r3)])
        #expect(!h.isLive(r3))
        let afterClaim = h.state
        #expect(h.send(.recoveryStep(r3, .followToEnd)).isEmpty)
        #expect(h.send(.recoveryStep(r3, .recover(pageOffsetY: 0))).isEmpty)
        #expect(h.send(.recoveryPagedUp(r3, mayFollowBack: true)).isEmpty)
        #expect(h.send(.recoveryFinished(r3, .giveUp, corrections: 1)).isEmpty)
        #expect(h.state == afterClaim)
        #expect(h.outcomes.isEmpty)
        #expect(h.goToEndShown == 0)
        #expect(h.scrolls == 1)

        #expect(h.send(.followDue(f2, execute: true)) == [.scrollToEnd])
        #expect(h.send(.followFinished(f2, .executed(.landed))) == [.startRecoveryTask(r4)])
        #expect(h.state.armedRecovery == .polling(r4))
        #expect(h.liveRecoveries == [r4])
        #expect(h.liveFollows.isEmpty)
    }

    /// Migrated from `recoveryDrainReplaysTheEdgeTheCorrectionSuppressed`: a
    /// correction in flight counts as a follow, so an away edge under it
    /// neither scrolls away nor re-pins; the drain replays that edge with
    /// the flag released. Recovered (the end row realized) short of the
    /// end, the viewport is re-pinned by the growth path; yielded under the
    /// finger, the edge is the gesture it is — scrolled away, nothing
    /// scrolls the user back, and the outcome reports as
    /// `endRecovery=yieldToUser`; yielded to a follow that claimed the
    /// viewport, the landing is the follow's and the replay re-pins nothing
    /// over it; recovered at the bottom, the edge does nothing.
    @Test func aCorrectionSuppressesTheGrowthRePinUntilItsDrainReplaysTheEdge() {
        var h = harness()
        #expect(h.send(.endDerealized) == [.startRecoveryTask(r1)])
        #expect(h.poll(geometry(offsetY: 260)) == .continue(.followToEnd))
        #expect(h.send(.recoveryStep(r1, .followToEnd)) == [Log.followToEnd, .scrollToEnd])
        #expect(h.state.isFollowing)
        h.geometryEdge(distanceToBottom: 120)
        #expect(!h.userIsScrolledAway)
        #expect(h.rePins == 0)
        #expect(h.poll(geometry(offsetY: 260), correctionsLeft: 1, correctionsSpent: 1) == .continue(.recover(pageOffsetY: 0)))
        #expect(h.send(.recoveryStep(r1, .recover(pageOffsetY: 0))) == [Log.pageUp, .pageUp(offsetY: 0)])
        h.distanceToBottom = 300
        var toFollow = h

        #expect(h.mayFollowBack())
        #expect(h.send(.recoveryPagedUp(r1, mayFollowBack: true)) == [.scrollToEnd])
        #expect(h.send(.endRealized(userIsScrolledAway: false)).isEmpty)
        var atBottom = h
        h.distanceToBottom = 120
        #expect(h.poll(geometry(offsetY: 180), correctionsSpent: 2) == .finish(.notNeeded))
        #expect(h.send(.recoveryFinished(r1, .notNeeded, corrections: 2)) == [
            .recordRecoveryOutcome(.notNeeded, corrections: 2), .replayLiveEdge(isInteracting: nil),
        ])
        #expect(h.state.owner == .idle)
        #expect(!h.state.isFollowing)
        #expect(!h.userIsScrolledAway)
        #expect(h.rePins == 1)
        #expect(h.goToEndShown == 0)

        atBottom.distanceToBottom = 10
        #expect(atBottom.send(.recoveryFinished(r1, .notNeeded, corrections: 2)) == [
            .recordRecoveryOutcome(.notNeeded, corrections: 2), .replayLiveEdge(isInteracting: nil),
        ])
        #expect(!atBottom.userIsScrolledAway)
        #expect(atBottom.rePins == 0)

        var yielded = harness()
        #expect(yielded.send(.endDerealized) == [.startRecoveryTask(r1)])
        #expect(yielded.poll(blank) == .continue(.recover(pageOffsetY: 1_600)))
        #expect(yielded.send(.recoveryStep(r1, .recover(pageOffsetY: 1_600))) == [Log.pageUp, .pageUp(offsetY: 1_600)])
        yielded.isInteracting = true
        yielded.distanceToBottom = 120
        #expect(!yielded.mayFollowBack())
        #expect(yielded.send(.recoveryPagedUp(r1, mayFollowBack: false)) == [Log.recoveryYielded])
        #expect(yielded.send(.recoveryFinished(r1, .yieldToUser, corrections: 1)) == [
            .recordRecoveryOutcome(.yieldToUser, corrections: 1), .replayLiveEdge(isInteracting: nil),
        ])
        #expect(yielded.summaries == ["endRecovery=yieldToUser corrections=1"])
        #expect(yielded.userIsScrolledAway)
        #expect(yielded.rePins == 0)
        #expect(yielded.goToEndShown == 0)
        #expect(yielded.scrolls == 0)

        #expect(toFollow.send(.followRequested(forced: false)) == [.startFollowTask(f2, forced: false)])
        #expect(toFollow.state.armedRecovery == .demoted(r1))
        #expect(!toFollow.mayFollowBack())
        #expect(toFollow.send(.recoveryPagedUp(r1, mayFollowBack: false)).isEmpty)
        toFollow.distanceToBottom = 120
        #expect(toFollow.send(.recoveryFinished(r1, .yieldToUser, corrections: 2)) == [
            .recordRecoveryOutcome(.yieldToUser, corrections: 2), .replayLiveEdge(isInteracting: nil),
        ])
        #expect(toFollow.state.owner == .follow(f2, forced: false))
        #expect(toFollow.state.armedRecovery == nil)
        #expect(!toFollow.userIsScrolledAway)
        #expect(toFollow.rePins == 0)
        #expect(toFollow.scrolls == 1)
    }

    /// Migrated from `recoveryGiveUpShowsGoToEndInsteadOfRePinningBlind`:
    /// the budget spent short of the end inside the band (or the deadline
    /// passed at the bottom over the blank) gives up, and the give-up shows
    /// Go to End where the edge alone would have re-pinned blind to a row
    /// that is not there. Scrolled away, growth re-pins nothing over the
    /// button; the tap follows through the verified path and its executed
    /// drain re-arms the recovery from the level. The outcome reports as
    /// `endRecovery=giveUp` with the corrections spent.
    @Test func aGiveUpShowsGoToEndInsteadOfRePinningBlind() {
        var h = harness()
        #expect(h.send(.endDerealized) == [.startRecoveryTask(r1)])
        #expect(h.poll(geometry(offsetY: 260)) == .continue(.followToEnd))
        #expect(h.send(.recoveryStep(r1, .followToEnd)) == [Log.followToEnd, .scrollToEnd])
        #expect(h.poll(geometry(offsetY: 260), correctionsLeft: 1, correctionsSpent: 1) == .continue(.recover(pageOffsetY: 0)))
        #expect(h.send(.recoveryStep(r1, .recover(pageOffsetY: 0))) == [Log.pageUp, .pageUp(offsetY: 0)])
        h.distanceToBottom = 300
        let followBack = h.mayFollowBack()
        #expect(followBack)
        #expect(h.send(.recoveryPagedUp(r1, mayFollowBack: followBack)) == [.scrollToEnd])
        h.distanceToBottom = 40
        #expect(h.poll(geometry(offsetY: 260), correctionsLeft: 0, correctionsSpent: 2) == .finish(.giveUp))
        #expect(h.poll(geometry(offsetY: 300), correctionsSpent: 2, timedOut: true) == .finish(.giveUp))
        h.isInteracting = true
        #expect(h.poll(geometry(offsetY: 300), timedOut: true) == .finish(.giveUp))
        h.isInteracting = false
        #expect(h.send(.recoveryFinished(r1, .giveUp, corrections: 2)) == [
            .recordRecoveryOutcome(.giveUp, corrections: 2), Log.gaveUp, .showGoToEnd,
        ])
        #expect(h.summaries == ["endRecovery=giveUp corrections=2"])
        #expect(h.userIsScrolledAway)
        #expect(h.goToEndShown == 1)
        #expect(h.rePins == 0)
        #expect(h.scrolls == 2)
        #expect(h.state.owner == .idle)
        #expect(h.state.currentRecovery == nil)
        h.geometryEdge(distanceToBottom: 120)
        #expect(h.userIsScrolledAway)
        #expect(h.rePins == 0)
        #expect(h.tapGoToEnd() == [.startFollowTask(f2, forced: true)])
        #expect(!h.userIsScrolledAway)
        h.distanceToBottom = 40
        #expect(h.execute())
        #expect(h.send(.followDue(f2, execute: true)) == [.scrollToEnd])
        #expect(h.send(.followFinished(f2, .executed(.landed))) == [.startRecoveryTask(r3)])
        #expect(h.state.armedRecovery == .polling(r3))
        #expect(h.isLive(r3))
        #expect(h.goToEndShown == 1)
        #expect(h.scrolls == 3)
    }
}
