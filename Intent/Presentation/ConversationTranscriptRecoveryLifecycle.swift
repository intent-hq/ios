import CoreGraphics
import Foundation

/// The one transition every handoff between the transcript's unrealized-end
/// recovery (#338), its follows to the end and the user's takeover goes
/// through. The view coordinated these by hand — a follow flag here, a
/// deferral boolean there — and each of the #350 defects was a handoff one
/// path forgot: a give-up whose follow was cancelled, a correction scrolling
/// over the user, a re-arm that never came. Here the viewport has exactly
/// one owner, every asynchronous continuation carries the token it was
/// started with and is ignored once that token is stale, and a give-up over
/// an unrealized end row is either shown as Go to End or transferred to the
/// follow that owns the viewport, whose terminal discharges it exactly once.
/// The reducer is pure: no clock, no task, no budget — the recovery and
/// landing loops keep their deadlines and correction counts and report the
/// resulting steps and terminals as events; the effects are executed by the
/// view in order.
enum ConversationTranscriptRecoveryLifecycle {
    typealias FollowTerminal = ConversationTranscriptScrollPolicy.FollowTerminal
    typealias RecoveryContinuation = ConversationTranscriptScrollPolicy.UnrealizedEndRecoveryContinuation
    typealias RecoveryTerminal = ConversationTranscriptScrollPolicy.UnrealizedEndRecoveryTerminal

    /// Identity of one requested follow, minted by `followRequested`; its
    /// debounce and landing loop report it back in their events.
    struct FollowToken: Hashable {
        let id: Int
    }

    /// Identity of one armed recovery, minted when the end row derealizes
    /// (or a follow drains over it); its polling loop reports it back.
    struct RecoveryToken: Hashable {
        let id: Int
    }

    /// Who may issue the next programmatic scroll. `isFollowing` for the
    /// geometry paths is `owner != .idle`.
    enum ViewportOwner: Equatable {
        case idle
        /// A follow from its request until its terminal is reported.
        case follow(FollowToken, forced: Bool)
        /// A recovery from its first correction until its terminal is
        /// reported — today's `isRecoveringUnrealizedEnd` — except while a
        /// follow requested meanwhile owns (`ArmedRecovery.demoted`).
        case recovery(RecoveryToken)
    }

    /// What happens to Go to End after a give-up over an unrealized end row
    /// while a follow owned the viewport. An exposed give-up is the
    /// `.showGoToEnd` effect, not a state.
    enum GiveUpFallback: Equatable {
        case none
        /// Discharged by exactly one terminal event for that follow (see
        /// `followFinished`, `followCancelledByGesture`); a follow that
        /// replaces it hands the transfer on.
        case transferred(to: FollowToken)
    }

    /// A recovery alive without owning the viewport. It may coexist with a
    /// follow owner: it reads `isFollowing` and settles until the follow
    /// drains.
    enum ArmedRecovery: Equatable {
        /// Polling without having claimed the viewport yet.
        case polling(RecoveryToken)
        /// Had claimed the viewport when a follow took it — today's
        /// `isRecoveringUnrealizedEnd` stays raised through the follow —
        /// and owns again once that follow drains.
        case demoted(RecoveryToken)

        var token: RecoveryToken {
            switch self {
            case .polling(let token), .demoted(let token): return token
            }
        }
    }

    struct State: Equatable {
        var owner: ViewportOwner = .idle
        var armedRecovery: ArmedRecovery? = nil
        var fallback: GiveUpFallback = .none
        /// The end row (the `scroll-bottom` marker) is realized by the lazy
        /// stack.
        var isEndRealized = false
        var nextTokenId = 1

        var isFollowing: Bool { owner != .idle }

        /// The one recovery task alive right now, armed or owning.
        var currentRecovery: RecoveryToken? {
            if let armedRecovery { return armedRecovery.token }
            switch owner {
            case .recovery(let token): return token
            case .idle, .follow: return nil
            }
        }
    }

    enum Event: Equatable {
        /// The end row disappeared from the lazy stack.
        case endDerealized
        /// The end row appeared; `userIsScrolledAway` is the flag at that
        /// moment.
        case endRealized(userIsScrolledAway: Bool)
        /// `scrollToBottom(forced:)`, after the view's own refusals (the
        /// takeover latch, the rate limit).
        case followRequested(forced: Bool)
        /// The debounce elapsed; `execute` is `shouldExecuteFollow`.
        case followDue(FollowToken, execute: Bool)
        case followFinished(FollowToken, FollowTerminal)
        /// A gesture took over: whichever owner and armed recovery there is.
        case followCancelledByGesture
        /// Go to End, or the user's own message: cancels the recovery only;
        /// the request's `followRequested` follows.
        case explicitClaim
        /// One intermediate poll of the recovery loop.
        case recoveryStep(RecoveryToken, RecoveryContinuation)
        /// The page up has had time to realize rows; `mayFollowBack` is
        /// `unrealizedEndRecoveryMayFollowBack`.
        case recoveryPagedUp(RecoveryToken, mayFollowBack: Bool)
        case recoveryFinished(RecoveryToken, RecoveryTerminal, corrections: Int)
        case viewDisappeared
    }

    /// Executed by the view in order.
    enum Effect: Equatable {
        case startFollowTask(FollowToken, forced: Bool)
        case cancelFollowTask(FollowToken)
        case startRecoveryTask(RecoveryToken)
        case cancelRecoveryTask(RecoveryToken)
        case scrollToEnd
        case pageUp(offsetY: CGFloat)
        /// Apply the live distance as a geometry edge; nil reads the live
        /// gesture state.
        case replayLiveEdge(isInteracting: Bool?)
        /// Flag the viewport scrolled away with no scroll issued over it.
        case showGoToEnd
        /// Record how the recovery ended with the corrections it spent; every
        /// terminal is recorded, a correction spent or not.
        case recordRecoveryOutcome(RecoveryTerminal, corrections: Int)
        case log(String)
    }

    /// The one transition. An event carrying a token that is neither the
    /// owner nor the armed recovery is stale — a continuation of a task
    /// that was cancelled or replaced — and returns the state unchanged
    /// with no effects.
    static func transition(_ state: State, _ event: Event) -> (state: State, effects: [Effect]) {
        var state = state
        var effects: [Effect] = []
        switch event {
        case .endDerealized:
            state.isEndRealized = false
            // A recovery already polling keeps its budget: it reads the end
            // row's state at every poll, so re-arming would only reset the
            // bound.
            if state.currentRecovery == nil {
                armRecovery(&state, &effects)
            }

        case .endRealized(let userIsScrolledAway):
            state.isEndRealized = true
            if userIsScrolledAway {
                effects.append(.replayLiveEdge(isInteracting: nil))
            }

        case .followRequested(let forced):
            switch state.owner {
            case .follow(let current, let currentForced):
                // A forced follow is never preempted by an automatic one.
                if currentForced, !forced { return (state, []) }
                effects.append(.cancelFollowTask(current))
            case .recovery(let recovery):
                // The follow owns the viewport from here; the recovery keeps
                // polling and settles until the follow drains, then owns
                // again.
                state.armedRecovery = .demoted(recovery)
            case .idle:
                break
            }
            let token = FollowToken(id: mintTokenId(&state))
            switch state.fallback {
            case .transferred:
                // The replacing follow inherits the give-up it must discharge.
                state.fallback = .transferred(to: token)
            case .none:
                break
            }
            state.owner = .follow(token, forced: forced)
            effects.append(.startFollowTask(token, forced: forced))

        case .followDue(let token, let execute):
            guard case .follow(token, let forced) = state.owner else { return (state, []) }
            if execute {
                effects.append(.scrollToEnd)
            } else if forced {
                effects.append(.log("[SCROLL] Forced follow yielded to the user's gesture"))
                effects.append(.replayLiveEdge(isInteracting: true))
            }

        case .followFinished(let token, let terminal):
            guard case .follow(token, let forced) = state.owner else { return (state, []) }
            state.owner = .idle
            if case .demoted(let recovery) = state.armedRecovery {
                // The correction the follow took the viewport from owns
                // again: the replayed edge reads `isFollowing`, and its
                // pending follow back is granted as it would have been.
                state.armedRecovery = nil
                state.owner = .recovery(recovery)
            }
            let transferred = dischargeFallback(&state, for: token)
            switch terminal {
            case .executed:
                if !forced {
                    effects.append(.replayLiveEdge(isInteracting: nil))
                }
                // The follow drained onto a still-unrealized end row: the
                // row was already unrealized when it claimed the viewport
                // and no new edge will come, so the recovery is re-armed
                // from the level.
                if !state.isEndRealized, state.currentRecovery == nil {
                    armRecovery(&state, &effects)
                }
            case .dropped, .yielded, .cancelled, .replaced:
                if transferred, !state.isEndRealized {
                    effects.append(.log("[SCROLL] End recovery gave up and the follow it deferred to did not execute; showing Go to End"))
                    effects.append(.showGoToEnd)
                } else if !forced {
                    effects.append(.replayLiveEdge(isInteracting: nil))
                }
            }

        case .followCancelledByGesture:
            var cancelledFollow: FollowToken?
            switch state.owner {
            case .follow(let token, let forced):
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
                effects.append(.log("[SCROLL] End recovery gave up and the follow it deferred to did not execute; showing Go to End"))
                effects.append(.showGoToEnd)
            }

        case .explicitClaim, .viewDisappeared:
            cancelRecovery(&state, &effects)

        case .recoveryStep(let token, let continuation):
            guard state.currentRecovery == token else { return (state, []) }
            switch continuation {
            case .settling:
                break
            case .followToEnd:
                guard claimViewport(&state, for: token) else { return (state, []) }
                effects.append(.log("[SCROLL] End row off screen short of the bottom; following to the end"))
                effects.append(.scrollToEnd)
            case .recover(let pageOffsetY):
                guard claimViewport(&state, for: token) else { return (state, []) }
                effects.append(.log("[SCROLL] Blank viewport at the bottom; paging up and following back"))
                effects.append(.pageUp(offsetY: pageOffsetY))
            }

        case .recoveryPagedUp(let token, let mayFollowBack):
            // The follow back re-checks the claim once the rows have
            // realized rather than scroll over a follow that took the
            // viewport meanwhile; a current recovery demoted under that
            // follow still reports its yield.
            guard state.currentRecovery == token else { return (state, []) }
            if !mayFollowBack {
                effects.append(.log("[SCROLL] End recovery yielded the paged-up viewport to the user"))
            } else if state.owner == .recovery(token) {
                effects.append(.scrollToEnd)
            }

        case .recoveryFinished(let token, let terminal, let corrections):
            guard state.currentRecovery == token else { return (state, []) }
            effects.append(.recordRecoveryOutcome(terminal, corrections: corrections))
            state.armedRecovery = nil
            if state.owner == .recovery(token) {
                state.owner = .idle
            }
            switch terminal {
            case .giveUp:
                // The budget is spent over a still-unrealized row: a re-pin
                // from the live edge would scroll blind to a row that is not
                // there, so Go to End is shown — or, with a follow owning
                // the viewport, transferred to that follow's terminal, since
                // flagging the viewport away now would cancel the follow as
                // a takeover.
                switch state.owner {
                case .follow(let follow, _):
                    state.fallback = .transferred(to: follow)
                    effects.append(.replayLiveEdge(isInteracting: nil))
                case .recovery, .idle:
                    effects.append(.log("[SCROLL] End recovery gave up over an unrealized end row; showing Go to End"))
                    effects.append(.showGoToEnd)
                }
            case .notNeeded, .yieldToUser:
                effects.append(.replayLiveEdge(isInteracting: nil))
            }
        }
        return (state, effects)
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

    /// Cancels whichever recovery is alive, armed or owning.
    private static func cancelRecovery(_ state: inout State, _ effects: inout [Effect]) {
        guard let token = state.currentRecovery else { return }
        effects.append(.cancelRecoveryTask(token))
        state.armedRecovery = nil
        if state.owner == .recovery(token) {
            state.owner = .idle
        }
    }

    /// A correction claims the viewport unless a follow owns it: the step
    /// function settles under a follow, and the reducer refuses too.
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

    /// Consumes a fallback transferred to `token`; returns whether one was.
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
