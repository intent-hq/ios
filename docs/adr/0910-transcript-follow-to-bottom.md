# ADR-0910: Transcript follow to bottom

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConversationTranscriptView+Follow.swift` (`Intent/Views/Conversation/Transcript/ConversationTranscriptView+Follow.swift`): `send(_:proxy:animated:)`, `perform(_:proxy:animated:)`, `takeOverPendingFollowIfGesture(proxy:)`, `cancelPendingFollowOnTakeover(proxy:)`, `claimViewportForExplicitFollow(proxy:)`, `scrollToBottom(proxy:forced:animated:)`, `runFollow(_:forced:animated:proxy:)`, `issueScrollToBottom(proxy:animated:)`; `ConversationTranscriptRecoveryLifecycle`

## Context

The transcript follows new content to the bottom. A follow is automatic (a
streaming delta) or forced (Go to End, the user's own message, the entry
scroll). Follows and unrealized-end recoveries share one lifecycle,
`ConversationTranscriptRecoveryLifecycle`. The user's gestures must always win.

## Decisions

### 1. One transition function drives the lifecycle

Applies to: `send(_:proxy:animated:)`, `perform(_:proxy:animated:)`

`send` is the one transition of the follow and unrealized-end recovery
lifecycle. The next state is stored first, then every effect runs in order.
The effects are returned.

`animated` is the animation of the `.scrollToEnd` that the event issues and of
the follow that a `.startFollowTask` begins. A follow uses its own animation; a
recovery's corrections use none. Reduce Motion drops it for every effect.

A forced follow that starts raises `isScrollingToBottom` and resets its demo
report. A follow that is cancelled releases the flag. A follow that drains
releases it itself (see `runFollow`).

### 2. A gesture takes over a pending follow at once

Applies to: `takeOverPendingFollowIfGesture(proxy:)`,
`ConversationTranscriptScrollPolicy.gestureTakesOverPendingFollow`

A gesture seen while a follow is pending takes the follow over immediately.
A gesture is a user-driven scroll phase beginning, or a geometry edge under
UIKit tracking, dragging, or deceleration. Waiting until the task comes due is
not enough: the gesture's final away edge can be dropped and its ending
delivered first. The check would then read idle and pinned and scroll the user
back.

### 3. What a takeover consumes

Applies to: `cancelPendingFollowOnTakeover(proxy:)`

The takeover consumes any follow that is still pending: an automatic one in
its debounce, a forced one in its debounce or its landing loop, or an
unrealized-end correction between its page up and its follow back.

Every forced follow is requested from a pinned viewport, so the gesture came
after the request and wins. The request is not kept for after the gesture
ends. Its takeover is latched (`forcedFollowTakenOverByGesture`), so a forced
follow that content raises meanwhile does not revive it. The lifecycle cancels
whichever owner and armed recovery exist, and shows Go to End for a give-up it
had transferred to the cancelled follow. The execution and landing checks
cover the frame before this runs. Go to End tapped afterwards is a fresh
request.

### 4. An explicit request takes the viewport back

Applies to: `claimViewportForExplicitFollow(proxy:)`

An explicit request (Go to End, or the user's own message) takes the viewport
back from any gesture. The takeover latch is released, and the SwiftUI phase is
no longer the gesture's. So a phase ending delivered after the request (the
fling it stopped, or the lift of the tap that sent the message) is not applied
as the gesture's final sample and does not take the request's follow over. An
unrealized-end recovery in flight is cancelled too, because the request's
follow owns the viewport.

### 5. Follow requests

Applies to: `scrollToBottom(proxy:forced:animated:)`,
`ConversationTranscriptScrollPolicy.shouldHonorForcedFollow`

1. The request time is stamped up front, so deltas inside the debounce window
   are rejected by the policy instead of restarting the debounce.
2. Automatic follows never preempt forced ones; the lifecycle refuses the
   request.
3. A user gesture cancels either kind at once (see
   `takeOverPendingFollowIfGesture`).
4. A forced follow raised while a gesture's takeover is latched is refused.
5. A request over a pending follow replaces it. The lifecycle cancels the old
   task and starts the new one, which inherits a give-up that the recovery had
   transferred to the old one.

### 6. The life of one follow

Applies to: `runFollow(_:forced:animated:proxy:)`

A follow runs from its debounce to its terminal.

1. Automatic follows are checked again by the policy after the debounce, so a
   user who scrolled away meanwhile is not snapped back.
2. A forced follow keeps `isScrollingToBottom` raised for its whole duration.
   It is complete only when the live geometry confirms its landing (see
   `awaitForcedFollowLanding`). It yields when the user is interacting, or has
   already scrolled away, as it comes due.
3. An automatic follow rides the bottom anchor and waits out its animation.
   Growth edges are suppressed while it is in flight. So when it drains,
   executed or dropped, the lifecycle replays the live distance once as the
   edge it may have swallowed. Content that grew past the band during the
   debounce with no gesture is re-pinned, not left short with Go to End
   hidden.
4. The terminal also resolves a give-up that the end recovery transferred to
   this follow. Dropped or yielded over an unrealized end row, Go to End is
   shown and no edge is replayed. The terminal re-arms the recovery when the
   follow executed over a still-unrealized end row.
5. A cancelled follow bails out silently, because the lifecycle that
   cancelled it has resolved its state.

### 7. Scroll to the tail while the end row is unrealized

Applies to: `issueScrollToBottom(proxy:animated:)`

The tail (`transcript-tail`) is a direct lazy-stack child, so SwiftUI can
realize it while its nested footer (`scroll-bottom`) is absent. Both targets
end at the footer.
