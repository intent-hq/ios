import CoreGraphics
@testable import Intent
import Testing

/// Transition-level tests of the recovery lifecycle reducer: each event
/// against each owner/fallback state it reads, with the contract's
/// invariants asserted on every transition through `step` — and, in the
/// `+Sequences` and `+EdgeSequences` files, each #350 handoff defect
/// replayed as one deterministic event sequence through `LifecycleHarness`,
/// which executes the effects against scripted geometry the way the view
/// does.
///
/// Mutation checks (each must fail deterministically):
/// - Removing the transfer discharge in `transition` (the
///   `dischargeFallback` call in `followFinished` / `followCancelledByGesture`)
///   fails `aGiveUpUnderAPendingAutomaticFollowIsShownWhenThatFollowIsDropped`
///   and `aTransferredGiveUpIsDischargedOnceByYieldOrCancel`: the drain
///   replays the edge as a raw re-pin (`rePins`) with Go to End hidden.
/// - Removing the realization gate — the `isEndRealized` guard in
///   `ConversationTranscriptScrollPolicy.scrolledAwayTransition`, or the
///   `replayLiveEdge` the reducer's `endRealized` issues — fails
///   `anAtBottomEdgeOverTheBlankKeepsGoToEndUntilTheMarkerRealizes`: the
///   blank's at-bottom edge clears the flag early, or the realization never
///   does.
struct TranscriptRecoveryLifecycleTests {
    typealias Lifecycle = ConversationTranscriptRecoveryLifecycle
    typealias State = Lifecycle.State
    typealias Event = Lifecycle.Event
    typealias Effect = Lifecycle.Effect
    typealias FollowToken = Lifecycle.FollowToken
    typealias RecoveryToken = Lifecycle.RecoveryToken

    let follow1 = FollowToken(id: 1)
    let follow2 = FollowToken(id: 2)
    let follow3 = FollowToken(id: 3)
    let recovery1 = RecoveryToken(id: 1)
    let recovery2 = RecoveryToken(id: 2)
    let recovery3 = RecoveryToken(id: 3)
    let recovery4 = RecoveryToken(id: 4)
    let staleFollow = FollowToken(id: 99)
    let staleRecovery = RecoveryToken(id: 99)

    // MARK: - Fixtures

    func followOwner(of state: State) -> FollowToken? {
        if case .follow(let token, _) = state.owner { return token }
        return nil
    }

    private func isLog(_ effect: Effect) -> Bool {
        if case .log = effect { return true }
        return false
    }

    func nonLog(_ effects: [Effect]) -> [Effect] { effects.filter { !isLog($0) } }

    func logs(_ effects: [Effect]) -> [String] {
        effects.compactMap { effect in
            if case .log(let message) = effect { return message }
            return nil
        }
    }

    func makeState(
        owner: Lifecycle.ViewportOwner = .idle,
        armed: Lifecycle.ArmedRecovery? = nil,
        fallback: Lifecycle.GiveUpFallback = .none,
        realized: Bool = false,
        next: Int = 3
    ) -> State {
        State(owner: owner, armedRecovery: armed, fallback: fallback, isEndRealized: realized, nextTokenId: next)
    }

    /// A pinned transcript at rest at the bottom, its end row realized.
    func makeHarness(realized: Bool = true, scrolledAway: Bool = false) -> LifecycleHarness {
        LifecycleHarness(state: State(isEndRealized: realized), userIsScrolledAway: scrolledAway, check: checkInvariants)
    }

    /// Content 1 000 in a 700 container: offset 300 is the bottom, 260 is
    /// 40 short (inside the band), 180 is 120 short.
    func geometry(offsetY: CGFloat, contentHeight: CGFloat = 1000) -> Geometry {
        Geometry(contentOffsetY: offsetY, contentHeight: contentHeight, containerHeight: 700, topInset: 0, bottomInset: 0)
    }

    /// A viewport the geometry calls the bottom over a blank lazy stack.
    var blank: Geometry { geometry(offsetY: 2300, contentHeight: 3000) }

    /// A recovery polling under a follow requested meanwhile times out over
    /// the blank: the give-up is transferred to that follow.
    func transferredGiveUp(forced: Bool) -> LifecycleHarness {
        var harness = makeHarness()
        #expect(harness.send(.endDerealized) == [.startRecoveryTask(recovery1)])
        #expect(harness.send(.followRequested(forced: forced)) == [.startFollowTask(follow2, forced: forced)])
        #expect(harness.state.armedRecovery == .polling(recovery1))
        #expect(harness.poll(geometry(offsetY: 300)) == .continue(.settling))
        #expect(harness.send(.recoveryStep(recovery1, .settling)).isEmpty)
        #expect(harness.poll(geometry(offsetY: 300), timedOut: true) == .finish(.giveUp))
        #expect(harness.send(.recoveryFinished(recovery1, .giveUp, corrections: 0)) == [
            .recordRecoveryOutcome(.giveUp, corrections: 0), .replayLiveEdge(.live)
        ])
        #expect(harness.state.fallback == .transferred(follow: follow2))
        #expect(harness.state.armedRecovery == nil)
        #expect(harness.outcomes == [.recordRecoveryOutcome(.giveUp, corrections: 0)])
        #expect(!harness.userIsScrolledAway)
        return harness
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
        var state = State()
        #expect(step(&state, .endDerealized) == [.startRecoveryTask(recovery1)])
        #expect(state.armedRecovery == .polling(recovery1))
        #expect(state.owner == .idle)
        #expect(!state.isFollowing)
        // A recovery already polling keeps its budget.
        #expect(step(&state, .endDerealized).isEmpty)
        #expect(state.armedRecovery == .polling(recovery1))
    }

    @Test func endDerealizedArmsNothingWhileARecoveryOwns() {
        var state = makeState(owner: .recovery(recovery1), realized: true)
        #expect(step(&state, .endDerealized).isEmpty)
        #expect(!state.isEndRealized)
        #expect(state.owner == .recovery(recovery1))
        #expect(state.armedRecovery == nil)
    }

    @Test func endDerealizedArmsUnderAFollowOwner() {
        var state = makeState(owner: .follow(follow1, forced: true), realized: true)
        #expect(step(&state, .endDerealized) == [.startRecoveryTask(RecoveryToken(id: 3))])
        #expect(state.owner == .follow(follow1, forced: true))
        #expect(state.armedRecovery == .polling(RecoveryToken(id: 3)))
        #expect(state.isFollowing)
    }

    @Test func endRealizedReplaysOnlyWhenScrolledAway() {
        var state = makeState(armed: .polling(recovery1))
        #expect(step(&state, .endRealized(userIsScrolledAway: false)).isEmpty)
        #expect(state.isEndRealized)
        #expect(state.armedRecovery == .polling(recovery1))
        state.isEndRealized = false
        #expect(step(&state, .endRealized(userIsScrolledAway: true)) == [.replayLiveEdge(.live)])
        #expect(state.isEndRealized)
        #expect(state.armedRecovery == .polling(recovery1))
    }
}
