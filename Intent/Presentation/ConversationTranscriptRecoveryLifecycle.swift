import CoreGraphics
import Foundation

enum ConversationTranscriptRecoveryLifecycle {
    typealias FollowTerminal = ConversationTranscriptScrollPolicy.FollowTerminal
    typealias RecoveryContinuation = ConversationTranscriptScrollPolicy.UnrealizedEndRecoveryContinuation
    typealias RecoveryTerminal = ConversationTranscriptScrollPolicy.UnrealizedEndRecoveryTerminal

    struct FollowToken: Hashable {
        let id: Int
    }

    struct RecoveryToken: Hashable {
        let id: Int
    }

    enum ViewportOwner: Equatable {
        case follow(FollowToken, forced: Bool)
        case idle
        case recovery(RecoveryToken)
    }

    enum GiveUpFallback: Equatable {
        case none
        case transferred(follow: FollowToken)
    }

    enum ArmedRecovery: Equatable {
        case demoted(RecoveryToken)
        case polling(RecoveryToken)

        var token: RecoveryToken {
            switch self {
            case .polling(let token), .demoted(let token): return token
            }
        }
    }

    enum Visibility: Equatable {
        case inactive
        case visible
    }

    struct State: Equatable {
        var visibility: Visibility = .inactive
        var owner: ViewportOwner = .idle
        var armedRecovery: ArmedRecovery?
        var fallback: GiveUpFallback = .none
        var isEndRealized = false
        var nextTokenId = 1

        var isVisible: Bool { visibility == .visible }
        var isFollowing: Bool { owner != .idle }

        var currentRecovery: RecoveryToken? {
            if let armedRecovery { return armedRecovery.token }
            switch owner {
            case .recovery(let token): return token
            case .idle, .follow: return nil
            }
        }
    }

    enum Event: Equatable {
        case endDerealized
        case endRealized(userIsScrolledAway: Bool)
        case explicitClaim
        case followCancelledByGesture
        case followDue(FollowToken, execute: Bool)
        case followFinished(FollowToken, FollowTerminal)
        case followRequested(forced: Bool)
        case recoveryFinished(RecoveryToken, RecoveryTerminal, corrections: Int)
        case recoveryPagedUp(RecoveryToken, mayFollowBack: Bool)
        case recoveryStep(RecoveryToken, RecoveryContinuation)
        case viewAppeared
        case viewDisappeared
    }

    enum LiveEdgeSample: Equatable {
        case live
        case sampled(isInteracting: Bool)

        func isInteracting(live: Bool) -> Bool {
            switch self {
            case .live: return live
            case .sampled(let isInteracting): return isInteracting
            }
        }
    }

    enum Effect: Equatable {
        case cancelFollowTask(FollowToken)
        case cancelRecoveryTask(RecoveryToken)
        case log(String)
        case pageUp(offsetY: CGFloat)
        case recordRecoveryOutcome(RecoveryTerminal, corrections: Int)
        case replayLiveEdge(LiveEdgeSample)
        case scrollToEnd
        case showGoToEnd
        case startFollowTask(FollowToken, forced: Bool)
        case startRecoveryTask(RecoveryToken)
    }

    static func transition(_ state: State, _ event: Event) -> (state: State, effects: [Effect]) {
        var state = state
        var effects: [Effect] = []
        switch event {
        case .viewAppeared:
            viewAppeared(&state, &effects)
        case .viewDisappeared:
            viewDisappeared(&state, &effects)
        case .endDerealized:
            endDerealized(&state, &effects)
        case .endRealized(let userIsScrolledAway):
            endRealized(userIsScrolledAway: userIsScrolledAway, &state, &effects)
        default:
            if state.isVisible { transitionVisibleWork(&state, event, &effects) }
        }
        return (state, effects)
    }
}

extension ConversationTranscriptRecoveryLifecycle {
    private static func transitionVisibleWork(_ state: inout State, _ event: Event, _ effects: inout [Effect]) {
        switch event {
        case .explicitClaim:
            cancelRecovery(&state, &effects)
        case .followCancelledByGesture:
            followCancelledByGesture(&state, &effects)
        case let .followDue(token, execute):
            followDue(token, execute: execute, &state, &effects)
        case let .followFinished(token, terminal):
            followFinished(token, terminal, &state, &effects)
        case .followRequested(let forced):
            followRequested(forced: forced, &state, &effects)
        case let .recoveryFinished(token, terminal, corrections):
            recoveryFinished(token, terminal, corrections: corrections, &state, &effects)
        case let .recoveryPagedUp(token, mayFollowBack):
            recoveryPagedUp(token, mayFollowBack: mayFollowBack, &state, &effects)
        case let .recoveryStep(token, continuation):
            recoveryStep(token, continuation, &state, &effects)
        case .endDerealized, .endRealized, .viewAppeared, .viewDisappeared:
            break
        }
    }

    // MARK: - Per-event transitions

    private static func viewAppeared(_ state: inout State, _ effects: inout [Effect]) {
        guard !state.isVisible else { return }
        state.visibility = .visible
        if !state.isEndRealized { armRecovery(&state, &effects) }
    }

    private static func viewDisappeared(_ state: inout State, _ effects: inout [Effect]) {
        if case .follow(let token, _) = state.owner {
            effects.append(.cancelFollowTask(token))
        }
        cancelRecovery(&state, &effects)
        state.visibility = .inactive
        state.owner = .idle
        state.fallback = .none
        state.isEndRealized = false
    }

    private static func endDerealized(_ state: inout State, _ effects: inout [Effect]) {
        state.isEndRealized = false
        if state.isVisible, state.currentRecovery == nil {
            armRecovery(&state, &effects)
        }
    }

    private static func endRealized(userIsScrolledAway: Bool, _ state: inout State, _ effects: inout [Effect]) {
        state.isEndRealized = true
        if state.isVisible, userIsScrolledAway {
            effects.append(.replayLiveEdge(.live))
        }
    }

    private static func followRequested(forced: Bool, _ state: inout State, _ effects: inout [Effect]) {
        switch state.owner {
        case let .follow(current, currentForced):
            if currentForced, !forced { return }
            effects.append(.cancelFollowTask(current))
        case .recovery(let recovery):
            state.armedRecovery = .demoted(recovery)
        case .idle:
            break
        }
        let token = FollowToken(id: mintTokenId(&state))
        switch state.fallback {
        case .transferred:
            state.fallback = .transferred(follow: token)
        case .none:
            break
        }
        state.owner = .follow(token, forced: forced)
        effects.append(.startFollowTask(token, forced: forced))
    }

    private static func followDue(_ token: FollowToken, execute: Bool, _ state: inout State, _ effects: inout [Effect]) {
        guard case .follow(token, let forced) = state.owner else { return }
        if execute {
            effects.append(.scrollToEnd)
        } else if forced {
            effects.append(.log("[SCROLL] Forced follow yielded to the user's gesture"))
            effects.append(.replayLiveEdge(.sampled(isInteracting: true)))
        }
    }

    private static func followFinished(
        _ token: FollowToken, _ terminal: FollowTerminal, _ state: inout State, _ effects: inout [Effect]
    ) {
        guard case .follow(token, let forced) = state.owner else { return }
        state.owner = .idle
        if case .demoted(let recovery) = state.armedRecovery {
            state.armedRecovery = nil
            state.owner = .recovery(recovery)
        }
        let transferred = dischargeFallback(&state, for: token)
        switch terminal {
        case .executed:
            if !forced {
                effects.append(.replayLiveEdge(.live))
            }
            if !state.isEndRealized, state.currentRecovery == nil {
                armRecovery(&state, &effects)
            }
        case .dropped, .yielded, .cancelled, .replaced:
            if transferred, !state.isEndRealized {
                showDeferredGiveUp(&effects)
            } else if !forced {
                effects.append(.replayLiveEdge(.live))
            }
        }
    }

    private static func followCancelledByGesture(_ state: inout State, _ effects: inout [Effect]) {
        var cancelledFollow: FollowToken?
        switch state.owner {
        case let .follow(token, forced):
            if forced {
                effects.append(.log("[SCROLL] Forced follow cancelled: the user took over"))
            }
            effects.append(.cancelFollowTask(token))
            cancelledFollow = token
        case .recovery, .idle:
            break
        }
        cancelRecovery(&state, &effects)
        state.owner = .idle
        let transferred: Bool
        if let cancelledFollow {
            transferred = dischargeFallback(&state, for: cancelledFollow)
        } else {
            transferred = false
        }
        if transferred, !state.isEndRealized {
            showDeferredGiveUp(&effects)
        }
    }

    private static func recoveryStep(
        _ token: RecoveryToken, _ continuation: RecoveryContinuation, _ state: inout State, _ effects: inout [Effect]
    ) {
        guard state.currentRecovery == token else { return }
        switch continuation {
        case .settling:
            break
        case .followToEnd:
            guard claimViewport(&state, for: token) else { return }
            effects.append(.log("[SCROLL] End row off screen short of the bottom; following to the end"))
            effects.append(.scrollToEnd)
        case .recover(let pageOffsetY):
            guard claimViewport(&state, for: token) else { return }
            effects.append(.log("[SCROLL] Blank viewport at the bottom; paging up and following back"))
            effects.append(.pageUp(offsetY: pageOffsetY))
        }
    }

    private static func recoveryPagedUp(
        _ token: RecoveryToken, mayFollowBack: Bool, _ state: inout State, _ effects: inout [Effect]
    ) {
        guard state.currentRecovery == token else { return }
        if !mayFollowBack {
            effects.append(.log("[SCROLL] End recovery yielded the paged-up viewport to the user"))
        } else if state.owner == .recovery(token) {
            effects.append(.scrollToEnd)
        }
    }

    private static func recoveryFinished(
        _ token: RecoveryToken, _ terminal: RecoveryTerminal, corrections: Int, _ state: inout State, _ effects: inout [Effect]
    ) {
        guard state.currentRecovery == token else { return }
        effects.append(.recordRecoveryOutcome(terminal, corrections: corrections))
        state.armedRecovery = nil
        if state.owner == .recovery(token) {
            state.owner = .idle
        }
        switch terminal {
        case .giveUp:
            switch state.owner {
            case .follow(let follow, _):
                state.fallback = .transferred(follow: follow)
                effects.append(.replayLiveEdge(.live))
            case .recovery, .idle:
                effects.append(.log("[SCROLL] End recovery gave up over an unrealized end row; showing Go to End"))
                effects.append(.showGoToEnd)
            }
        case .notNeeded, .yieldToUser:
            effects.append(.replayLiveEdge(.live))
        }
    }

    // MARK: - Shared steps

    private static func showDeferredGiveUp(_ effects: inout [Effect]) {
        effects.append(.log("[SCROLL] End recovery gave up and the follow it deferred to did not execute; showing Go to End"))
        effects.append(.showGoToEnd)
    }

    private static func mintTokenId(_ state: inout State) -> Int {
        defer { state.nextTokenId += 1 }
        return state.nextTokenId
    }

    private static func armRecovery(_ state: inout State, _ effects: inout [Effect]) {
        let token = RecoveryToken(id: mintTokenId(&state))
        state.armedRecovery = .polling(token)
        effects.append(.startRecoveryTask(token))
    }

    private static func cancelRecovery(_ state: inout State, _ effects: inout [Effect]) {
        guard let token = state.currentRecovery else { return }
        effects.append(.cancelRecoveryTask(token))
        state.armedRecovery = nil
        if state.owner == .recovery(token) {
            state.owner = .idle
        }
    }

    private static func claimViewport(_ state: inout State, for token: RecoveryToken) -> Bool {
        switch state.owner {
        case .follow:
            return false
        case .recovery:
            return true
        case .idle:
            state.armedRecovery = nil
            state.owner = .recovery(token)
            return true
        }
    }

    private static func dischargeFallback(_ state: inout State, for token: FollowToken) -> Bool {
        switch state.fallback {
        case .transferred(let follow) where follow == token:
            state.fallback = .none
            return true
        case .transferred, .none:
            return false
        }
    }
}
