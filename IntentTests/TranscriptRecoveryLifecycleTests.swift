import CoreGraphics
@testable import Intent
import Testing

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
        State(visibility: .visible, owner: owner, armedRecovery: armed, fallback: fallback, isEndRealized: realized, nextTokenId: next)
    }

    func makeHarness(realized: Bool = true, scrolledAway: Bool = false) -> LifecycleHarness {
        LifecycleHarness(state: State(visibility: .visible, isEndRealized: realized), userIsScrolledAway: scrolledAway, check: checkInvariants)
    }

    func geometry(offsetY: CGFloat, contentHeight: CGFloat = 1000) -> Geometry {
        Geometry(contentOffsetY: offsetY, contentHeight: contentHeight, containerHeight: 700, topInset: 0, bottomInset: 0)
    }

    var blank: Geometry { geometry(offsetY: 2300, contentHeight: 3000) }

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

    @Test func freshStateIsInactiveIdleAndUnrealized() {
        let fresh = State()
        #expect(fresh.visibility == .inactive)
        #expect(!fresh.isVisible)
        #expect(fresh.owner == .idle)
        #expect(fresh.armedRecovery == nil)
        #expect(fresh.fallback == .none)
        #expect(!fresh.isEndRealized)
        #expect(!fresh.isFollowing)
        #expect(fresh.currentRecovery == nil)
        #expect(fresh.nextTokenId == 1)
    }

    @Test func endDerealizedArmsExactlyOneRecovery() {
        var state = State(visibility: .visible)
        #expect(step(&state, .endDerealized) == [.startRecoveryTask(recovery1)])
        #expect(state.armedRecovery == .polling(recovery1))
        #expect(state.owner == .idle)
        #expect(!state.isFollowing)
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
