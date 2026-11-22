@testable import Intent
import Testing

extension TranscriptRecoveryLifecycleTests {
    @discardableResult
    func step(_ state: inout State, _ event: Event, sourceLocation: SourceLocation = #_sourceLocation) -> [Effect] {
        let before = state
        let (after, effects) = Lifecycle.transition(before, event)
        checkInvariants(before: before, event: event, after: after, effects: effects, sourceLocation: sourceLocation)
        state = after
        return effects
    }

    func checkInvariants(before: State, event: Event, after: State, effects: [Effect], sourceLocation: SourceLocation) {
        checkVisibility(before: before, event: event, after: after, effects: effects, sourceLocation: sourceLocation)
        checkOwnership(before: before, event: event, after: after, effects: effects, sourceLocation: sourceLocation)
        checkGiveUpResolution(before: before, event: event, after: after, effects: effects, sourceLocation: sourceLocation)
        checkTransferDischarge(before: before, event: event, after: after, effects: effects, sourceLocation: sourceLocation)
        checkGoToEndShownOnce(event: event, effects: effects, sourceLocation: sourceLocation)
        checkBudgetIdentity(before: before, event: event, after: after, effects: effects, sourceLocation: sourceLocation)
    }

    private func checkVisibility(before: State, event: Event, after: State, effects: [Effect], sourceLocation: SourceLocation) {
        if !after.isVisible {
            #expect(after.owner == .idle, "inactive transcript retained an owner", sourceLocation: sourceLocation)
            #expect(after.armedRecovery == nil, "inactive transcript retained a recovery", sourceLocation: sourceLocation)
            #expect(after.fallback == .none, "inactive transcript retained a give-up", sourceLocation: sourceLocation)
        }
        switch event {
        case .viewAppeared:
            #expect(after.isVisible, sourceLocation: sourceLocation)
            if before.isVisible {
                #expect(after == before, "duplicate appearance changed state", sourceLocation: sourceLocation)
                #expect(effects.isEmpty, "duplicate appearance produced effects", sourceLocation: sourceLocation)
            }
        case .viewDisappeared:
            checkDisappearance(before: before, after: after, effects: effects, sourceLocation: sourceLocation)
        default:
            #expect(after.visibility == before.visibility, sourceLocation: sourceLocation)
            guard !before.isVisible else { return }
            var expected = before
            switch event {
            case .endRealized: expected.isEndRealized = true
            case .endDerealized: expected.isEndRealized = false
            default: break
            }
            #expect(after == expected, "inactive event changed more than realization", sourceLocation: sourceLocation)
            #expect(effects.isEmpty, "inactive event produced effects", sourceLocation: sourceLocation)
        }
    }

    private func checkDisappearance(before: State, after: State, effects: [Effect], sourceLocation: SourceLocation) {
        #expect(!after.isVisible, sourceLocation: sourceLocation)
        #expect(!after.isEndRealized, sourceLocation: sourceLocation)
        #expect(after.nextTokenId == before.nextTokenId, sourceLocation: sourceLocation)
        var cancellations: [Effect] = []
        if let follow = followOwner(of: before) { cancellations.append(.cancelFollowTask(follow)) }
        if let recovery = before.currentRecovery { cancellations.append(.cancelRecoveryTask(recovery)) }
        #expect(effects == cancellations, "teardown must cancel follow before recovery, with no other effects", sourceLocation: sourceLocation)
    }

    private func checkOwnership(before: State, event: Event, after: State, effects: [Effect], sourceLocation: SourceLocation) {
        if case .transferred(let follow) = after.fallback {
            #expect(followOwner(of: after) == follow, "fallback transferred to a non-owner", sourceLocation: sourceLocation)
        }
        if let armed = after.armedRecovery {
            #expect(after.owner != .recovery(armed.token), "armed recovery also owns", sourceLocation: sourceLocation)
            if case .demoted = armed {
                #expect(followOwner(of: after) != nil, "demoted recovery with no follow owning", sourceLocation: sourceLocation)
            }
        }
        #expect(after.nextTokenId >= before.nextTokenId, "token counter went backwards", sourceLocation: sourceLocation)
        if isStale(event, in: before) {
            #expect(after == before, "stale token changed state", sourceLocation: sourceLocation)
            #expect(effects.isEmpty, "stale token produced effects", sourceLocation: sourceLocation)
        }
        if effects.contains(where: isScroll) {
            #expect(after.owner != .idle, "scroll issued with no owner", sourceLocation: sourceLocation)
        }
        if case .follow = before.owner {
            switch event {
            case .recoveryStep, .recoveryPagedUp:
                #expect(!effects.contains(where: isScroll), "correction scrolled over a follow", sourceLocation: sourceLocation)
            default:
                break
            }
        }
    }

    private func checkGiveUpResolution(
        before: State, event: Event, after: State, effects: [Effect], sourceLocation: SourceLocation
    ) {
        guard before.isVisible else { return }
        if case .recoveryFinished(let token, .giveUp, _) = event, before.currentRecovery == token, !before.isEndRealized {
            let shown = effects.contains(.showGoToEnd)
            var transferred = false
            if case .transferred(let follow) = after.fallback { transferred = followOwner(of: after) == follow }
            #expect(shown != transferred, "give-up neither shown nor transferred (or both)", sourceLocation: sourceLocation)
            if shown { #expect(after.owner == .idle, sourceLocation: sourceLocation) }
        }
        if case .endRealized(true) = event {
            #expect(effects.contains(.replayLiveEdge(.live)), sourceLocation: sourceLocation)
        }
    }

    private func checkTransferDischarge(
        before: State, event: Event, after: State, effects: [Effect], sourceLocation: SourceLocation
    ) {
        guard before.isVisible, case .transferred(let follow) = before.fallback else { return }
        if case .followRequested = event {
            if let owner = followOwner(of: after) {
                #expect(after.fallback == .transferred(follow: owner), "follow request did not carry the transfer to the owner", sourceLocation: sourceLocation)
            } else {
                Issue.record("follow request over a transfer left no follow owning", sourceLocation: sourceLocation)
            }
        }
        guard let terminal = transferTerminal(event, for: follow) else { return }
        #expect(after.fallback == .none, "terminal left the transfer", sourceLocation: sourceLocation)
        let shownByTerminal = effects.filter { $0 == .showGoToEnd }.count
        if terminal == .unexecuted, !before.isEndRealized {
            #expect(shownByTerminal == 1, "unexecuted terminal over an unrealized end did not show Go to End", sourceLocation: sourceLocation)
        } else {
            #expect(shownByTerminal == 0, "Go to End shown by an executed drain or over a realized end", sourceLocation: sourceLocation)
        }
        if terminal == .executed, !before.isEndRealized, before.currentRecovery == nil {
            #expect(effects.contains(where: isStartRecovery), "executed drain over an unrealized end did not re-arm", sourceLocation: sourceLocation)
        }
    }

    private func checkGoToEndShownOnce(event: Event, effects: [Effect], sourceLocation: SourceLocation) {
        let shown = effects.filter { $0 == .showGoToEnd }.count
        #expect(shown <= 1, "Go to End shown twice", sourceLocation: sourceLocation)
        if shown == 1 {
            switch event {
            case .recoveryFinished(_, .giveUp, _), .followFinished, .followCancelledByGesture:
                break
            case .endDerealized, .endRealized, .followRequested, .followDue, .explicitClaim, .recoveryStep,
                 .recoveryPagedUp, .recoveryFinished, .viewAppeared, .viewDisappeared:
                Issue.record("Go to End shown by \(event)", sourceLocation: sourceLocation)
            }
        }
    }

    private func checkBudgetIdentity(
        before: State, event: Event, after: State, effects: [Effect], sourceLocation: SourceLocation
    ) {
        let outcomes = effects.compactMap { effect -> (Lifecycle.RecoveryTerminal, Int)? in
            if case let .recordRecoveryOutcome(terminal, corrections) = effect { return (terminal, corrections) }
            return nil
        }
        if case let .recoveryFinished(token, terminal, corrections) = event, before.isVisible, before.currentRecovery == token {
            #expect(outcomes.count == 1, "outcome not recorded exactly once", sourceLocation: sourceLocation)
            #expect(outcomes.first?.0 == terminal, "outcome recorded a different terminal", sourceLocation: sourceLocation)
            #expect(outcomes.first?.1 == corrections, "outcome recorded a different count", sourceLocation: sourceLocation)
        } else {
            #expect(outcomes.isEmpty, "outcome recorded outside a current recovery terminal", sourceLocation: sourceLocation)
        }
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
            #expect(after.isVisible, "inactive transcript started recovery", sourceLocation: sourceLocation)
            switch event {
            case .viewAppeared:
                #expect(!before.isVisible, "duplicate appearance re-armed recovery", sourceLocation: sourceLocation)
                #expect(!before.isEndRealized, "appearance armed recovery over a realized end", sourceLocation: sourceLocation)
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

    private enum TransferTerminal {
        case executed
        case unexecuted
    }

    private func transferTerminal(_ event: Event, for follow: FollowToken) -> TransferTerminal? {
        switch event {
        case .followFinished(follow, .executed):
            return .executed
        case .followFinished(follow, .dropped), .followFinished(follow, .yielded),
             .followFinished(follow, .cancelled), .followFinished(follow, .replaced),
             .followCancelledByGesture:
            return .unexecuted
        case .endDerealized, .endRealized, .followDue, .followFinished, .followRequested, .explicitClaim,
             .recoveryStep, .recoveryPagedUp, .recoveryFinished, .viewAppeared, .viewDisappeared:
            return nil
        }
    }

    private func isStartRecovery(_ effect: Effect) -> Bool {
        if case .startRecoveryTask = effect { return true }
        return false
    }

    private func isStale(_ event: Event, in state: State) -> Bool {
        switch event {
        case .followDue(let token, _), .followFinished(let token, _):
            return followOwner(of: state) != token
        case .recoveryStep(let token, _), .recoveryPagedUp(let token, _), .recoveryFinished(let token, _, _):
            return state.currentRecovery != token
        case .endDerealized, .endRealized, .followRequested, .followCancelledByGesture, .explicitClaim, .viewAppeared, .viewDisappeared:
            return false
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
}
