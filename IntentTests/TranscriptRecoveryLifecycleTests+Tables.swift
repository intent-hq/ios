import CoreGraphics
@testable import Intent
import Testing

/// Token identity, and the two terminal events over every well-formed
/// owner / armed / fallback combination.
extension TranscriptRecoveryLifecycleTests {
    // MARK: - Identity

    @Test func staleTokensChangeNothing() {
        let states = [
            State(),
            makeState(owner: .follow(follow1, forced: true), armed: .polling(recovery2), fallback: .transferred(follow: follow1)),
            makeState(owner: .follow(follow1, forced: false), armed: .demoted(recovery2)),
            makeState(owner: .recovery(recovery1))
        ]
        let events: [Event] = [
            .followDue(staleFollow, execute: true), .followFinished(staleFollow, .executed(nil)),
            .followFinished(staleFollow, .dropped), .recoveryStep(staleRecovery, .followToEnd),
            .recoveryStep(staleRecovery, .recover(pageOffsetY: 10)), .recoveryPagedUp(staleRecovery, mayFollowBack: true),
            .recoveryFinished(staleRecovery, .giveUp, corrections: 1),
            .recoveryFinished(staleRecovery, .notNeeded, corrections: 0)
        ]
        for original in states {
            for event in events {
                var state = original
                #expect(step(&state, event).isEmpty, "\(event)")
                #expect(state == original, "\(event)")
            }
        }
    }

    @Test func aGestureTakeoverMakesEveryEarlierTokenStale() {
        var state = State()
        step(&state, .endDerealized)
        step(&state, .recoveryStep(recovery1, .recover(pageOffsetY: 80)))
        #expect(state.owner == .recovery(recovery1))
        #expect(step(&state, .followCancelledByGesture) == [.cancelRecoveryTask(recovery1)])
        #expect(step(&state, .recoveryPagedUp(recovery1, mayFollowBack: true)).isEmpty)
        #expect(step(&state, .recoveryStep(recovery1, .followToEnd)).isEmpty)
        #expect(step(&state, .recoveryFinished(recovery1, .giveUp, corrections: 1)).isEmpty)

        step(&state, .followRequested(forced: true))
        #expect(state.owner == .follow(follow2, forced: true))
        step(&state, .followCancelledByGesture)
        #expect(step(&state, .followDue(follow2, execute: true)).isEmpty)
        #expect(step(&state, .followFinished(follow2, .executed(.landed))).isEmpty)
        #expect(state.owner == .idle)
        #expect(state.currentRecovery == nil)
    }

    @Test func tokensAreMintedFromOneMonotonicCounter() {
        var state = State()
        #expect(step(&state, .endDerealized) == [.startRecoveryTask(RecoveryToken(id: 1))])
        #expect(step(&state, .followRequested(forced: false)) == [.startFollowTask(FollowToken(id: 2), forced: false)])
        #expect(nonLog(step(&state, .followRequested(forced: true))) == [
            .cancelFollowTask(FollowToken(id: 2)), .startFollowTask(FollowToken(id: 3), forced: true)
        ])
        step(&state, .explicitClaim)
        #expect(step(&state, .followFinished(FollowToken(id: 3), .executed(.landed))) == [
            .startRecoveryTask(RecoveryToken(id: 4))
        ])
        #expect(state.nextTokenId == 5)
    }

    // MARK: - Tables

    /// Every well-formed owner / armed / fallback combination the two
    /// terminal events can meet. `follow1` is the follow, `recovery2` the recovery. A
    /// demoted recovery exists only under a follow, and never with a
    /// transfer: a transfer names the follow that owns, while a demotion is
    /// made over an owning recovery.
    private var terminalStates: [State] {
        var states: [State] = []
        for realized in [false, true] {
            for armed in [nil, Lifecycle.ArmedRecovery.polling(recovery2)] {
                states.append(makeState(owner: .idle, armed: armed, realized: realized))
                for forced in [false, true] {
                    for fallback in [Lifecycle.GiveUpFallback.none, .transferred(follow: follow1)] {
                        states.append(makeState(owner: .follow(follow1, forced: forced), armed: armed, fallback: fallback, realized: realized))
                    }
                }
            }
            for forced in [false, true] {
                states.append(makeState(owner: .follow(follow1, forced: forced), armed: .demoted(recovery2), realized: realized))
            }
            states.append(makeState(owner: .recovery(recovery2), realized: realized))
        }
        return states
    }

    @Test func recoveryFinishedTable() {
        var cases = 0
        for original in terminalStates {
            for terminal in [Lifecycle.RecoveryTerminal.notNeeded, .giveUp, .yieldToUser] {
                for corrections in [0, 2] {
                    for token in [recovery2, staleRecovery] {
                        cases += 1
                        var state = original
                        let effects = nonLog(step(&state, .recoveryFinished(token, terminal, corrections: corrections)))
                        guard original.currentRecovery == token else {
                            #expect(effects.isEmpty)
                            #expect(state == original)
                            continue
                        }
                        var expected = original
                        var expectedEffects: [Effect] = [.recordRecoveryOutcome(terminal, corrections: corrections)]
                        expected.armedRecovery = nil
                        if expected.owner == .recovery(token) { expected.owner = .idle }
                        switch terminal {
                        case .giveUp:
                            if let follow = followOwner(of: expected) {
                                expected.fallback = .transferred(follow: follow)
                                expectedEffects.append(.replayLiveEdge(.live))
                            } else {
                                expectedEffects.append(.showGoToEnd)
                            }
                        case .notNeeded, .yieldToUser:
                            expectedEffects.append(.replayLiveEdge(.live))
                        }
                        #expect(state == expected, "\(original) \(terminal) \(corrections)")
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
            .executed(nil), .executed(.landed), .dropped, .yielded, .cancelled, .replaced
        ]
        var cases = 0
        for original in terminalStates {
            for terminal in terminals {
                for token in [follow1, staleFollow] {
                    cases += 1
                    var state = original
                    let effects = nonLog(step(&state, .followFinished(token, terminal)))
                    guard case .follow(token, let forced) = original.owner else {
                        #expect(effects.isEmpty)
                        #expect(state == original)
                        continue
                    }
                    let (expected, expectedEffects) = expectedDrain(of: original, token: token, forced: forced, terminal: terminal)
                    #expect(state == expected, "\(original) \(terminal)")
                    #expect(effects == expectedEffects, "\(original) \(terminal)")
                }
            }
        }
        #expect(cases == 26 * 6 * 2)
    }

    /// The contract's state and effects for the owning follow `token`
    /// draining from `original` with `terminal`.
    private func expectedDrain(
        of original: State, token: FollowToken, forced: Bool, terminal: Lifecycle.FollowTerminal
    ) -> (State, [Effect]) {
        var expected = original
        var expectedEffects: [Effect] = []
        expected.owner = .idle
        if case .demoted(let recovery) = original.armedRecovery {
            expected.owner = .recovery(recovery)
            expected.armedRecovery = nil
        }
        let transferred = original.fallback == .transferred(follow: token)
        expected.fallback = .none
        switch terminal {
        case .executed:
            if !forced { expectedEffects.append(.replayLiveEdge(.live)) }
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
                expectedEffects.append(.replayLiveEdge(.live))
            }
        }
        return (expected, expectedEffects)
    }
}
