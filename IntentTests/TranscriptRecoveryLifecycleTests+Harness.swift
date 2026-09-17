import CoreGraphics
@testable import Intent
import Testing

/// `LifecycleHarness`: the sequence tests' driver.
extension TranscriptRecoveryLifecycleTests {
    typealias Geometry = ConversationTranscriptScrollPolicy.ViewportGeometry
    typealias RecoveryStep = ConversationTranscriptScrollPolicy.UnrealizedEndRecoveryStep

    /// The reducer's log lines, so a sequence asserts each transition's
    /// full ordered effect list.
    enum LogLine {
        static let followToEnd = Effect.log("[SCROLL] End row off screen short of the bottom; following to the end")
        static let pageUp = Effect.log("[SCROLL] Blank viewport at the bottom; paging up and following back")
        static let recoveryYielded = Effect.log("[SCROLL] End recovery yielded the paged-up viewport to the user")
        static let gaveUp = Effect.log("[SCROLL] End recovery gave up over an unrealized end row; showing Go to End")
        static let deferredGaveUp = Effect.log(
            "[SCROLL] End recovery gave up and the follow it deferred to did not execute; showing Go to End"
        )
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
    /// `unrealizedEndRecoveryReport` as the demo-data report does; the
    /// recovery loop's polls go through `unrealizedEndRecoveryStep` against
    /// the live state. No clock: the sequence is the schedule. Every
    /// transition is checked against the contract's invariants.
    struct LifecycleHarness {
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
        var episodes = 0
        var outcomes: [Effect] = []
        var summaries: [String] = []
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
                apply(effect)
            }
            return effects
        }

        /// The task bookkeeping of one effect; the rest is rendered.
        private mutating func apply(_ effect: Effect) {
            switch effect {
            case .startFollowTask(let token, _): liveFollows.insert(token)
            case .cancelFollowTask(let token): liveFollows.remove(token)
            case .startRecoveryTask(let token):
                liveRecoveries.insert(token)
                episodes += 1
            case .cancelRecoveryTask(let token): liveRecoveries.remove(token)
            case .scrollToEnd, .pageUp, .replayLiveEdge, .showGoToEnd, .recordRecoveryOutcome, .log:
                render(effect)
            }
        }

        /// One effect executed against the scripted geometry, as the view does.
        private mutating func render(_ effect: Effect) {
            switch effect {
            case .scrollToEnd: scrolls += 1
            case .pageUp(let offsetY): pageUps.append(offsetY)
            case .replayLiveEdge(let sample): applyEdge(isInteracting: sample.isInteracting(live: isInteracting))
            case .showGoToEnd:
                userIsScrolledAway = true
                goToEndShown += 1
            case let .recordRecoveryOutcome(terminal, corrections):
                outcomes.append(effect)
                summaries.append(ConversationTranscriptScrollPolicy.unrealizedEndRecoveryReport(
                    outcome: terminal,
                    corrections: corrections,
                    episodes: episodes,
                    endRealized: state.isEndRealized,
                    cancelled: false
                ).summary)
            case .log, .startFollowTask, .cancelFollowTask, .startRecoveryTask, .cancelRecoveryTask: break
            }
        }

        /// A geometry edge from the scroll view: a layout settle, a content
        /// update, or a gesture phase ending, sampled with the live gesture.
        mutating func geometryEdge(distanceToBottom: CGFloat) {
            geometryEdge(distanceToBottom: distanceToBottom, isInteracting: isInteracting)
        }

        /// A geometry edge carrying its own gesture sample.
        mutating func geometryEdge(distanceToBottom: CGFloat, isInteracting sample: Bool) {
            self.distanceToBottom = distanceToBottom
            applyEdge(isInteracting: sample)
        }

        private mutating func applyEdge(isInteracting: Bool) {
            let geometryAway = ConversationTranscriptScrollPolicy.isScrolledAway(
                distanceToBottom: distanceToBottom,
                atBottomThreshold: Self.threshold
            )
            let next = ConversationTranscriptScrollPolicy.scrolledAwayTransition(
                current: userIsScrolledAway,
                geometryAway: geometryAway,
                isInteracting: isInteracting,
                isEndRealized: state.isEndRealized
            )
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
                atBottomThreshold: Self.threshold
            )
        }

        /// The page-up check, reading a follow pending as the view does.
        func mayFollowBack() -> Bool {
            ConversationTranscriptScrollPolicy.unrealizedEndRecoveryMayFollowBack(
                isInteracting: isInteracting,
                userIsScrolledAway: userIsScrolledAway,
                isFollowing: followOwns
            )
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
                atBottomThreshold: Self.threshold
            )
        }
    }
}
