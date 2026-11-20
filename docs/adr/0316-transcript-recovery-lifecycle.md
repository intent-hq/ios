# ADR-0316: One reducer owns the transcript viewport across follows and end recovery

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConversationTranscriptRecoveryLifecycle` (`Intent/Presentation/ConversationTranscriptRecoveryLifecycle.swift`), `ConversationTranscriptScrollState` follow and recovery members (`Intent/Presentation/ConversationTranscriptScrollState.swift`)
- Related issues: #304, #305, #338, #346, #350

## Context

The transcript follows new content to the end, recovers when the lazy stack
leaves the viewport resting on unrealized rows past the end row (#338), and
yields to the user's gestures. The view used to coordinate these by hand: a
follow flag here, a deferral boolean there. Each of the #350 defects was a
handoff that one path forgot: a give-up whose follow was cancelled, a
correction that scrolled over the user, a re-arm that never came.

## Decisions

### 1. Every handoff goes through one pure transition

Applies to: `ConversationTranscriptRecoveryLifecycle.transition(_:_:)`, `ConversationTranscriptScrollState.lifecycle`

Every handoff between the unrealized-end recovery, the follows to the end and
the user's takeover goes through `transition`.

1. The viewport has exactly one owner.
2. Every asynchronous continuation carries the token it was started with, and
   it is ignored once that token is stale.
3. A give-up over an unrealized end row is either shown as Go to End or
   transferred to the follow that owns the viewport. That follow's terminal
   discharges it exactly once.

The reducer is pure: no clock, no task, no budget. The recovery and landing
loops keep their deadlines and correction counts, and report the resulting
steps and terminals as events. The view executes the effects in order.

An event whose token is neither the owner nor the armed recovery is stale: it
is a continuation of a task that was cancelled or replaced. The transition then
returns the state unchanged with no effects. Each per-event function returns on
a stale token before it touches `state` or `effects`.

`ConversationTranscriptScrollState.lifecycle` is written only through
`transition`. It records who owns the viewport (a follow from its request to
its terminal, an unrealized-end correction from its first scroll to its
terminal), the recovery armed without owning, a give-up transferred to the
owning follow, and whether the end row (the `scroll-bottom` marker) is
realized by the lazy stack. `lifecycle` is not observed; only
`lifecycleOwnsViewport` is published, so ownership changes (including an
automatic follow that drains after recovery) redraw the view and the rest of
the reducer's polling state does not.

### 2. Tokens identify one follow or one recovery

Applies to: `FollowToken`, `RecoveryToken`, `ConversationTranscriptScrollState.followTasks`, `ConversationTranscriptScrollState.recoveryTasks`

A `FollowToken` identifies one requested follow. `followRequested` mints it,
and the follow's debounce and landing loop report it back in their events. A
`RecoveryToken` identifies one armed recovery. It is minted when the end row
derealizes, or when a follow drains over it, and its polling loop reports it
back. The scroll state keys its tasks by these tokens.

### 3. Ownership

Applies to: `ViewportOwner`, `ArmedRecovery`, `GiveUpFallback`, `State.currentRecovery`

`ViewportOwner` says who may issue the next programmatic scroll. For the
geometry paths, `isFollowing` is `owner != .idle`.

- `follow`: a follow, from its request until its terminal is reported.
- `recovery`: a recovery, from its first correction until its terminal is
  reported, except while a follow requested meanwhile owns the viewport
  (`ArmedRecovery.demoted`).

`ArmedRecovery` is a recovery that is alive without owning the viewport. It
can coexist with a follow owner: it reads `isFollowing` and settles until the
follow drains.

- `demoted`: it had claimed the viewport when a follow took it, and it owns
  again once that follow drains.
- `polling`: it is polling and has not claimed the viewport yet.

`currentRecovery` is the one recovery task alive, armed or owning.

`GiveUpFallback` says what happens to Go to End after a give-up over an
unrealized end row while a follow owned the viewport. A give-up shown at once
is the `showGoToEnd` effect, not a state. `transferred` is discharged by
exactly one terminal event for that follow (`followFinished`,
`followCancelledByGesture`). A follow that replaces it hands the transfer on.

### 4. Event and effect contracts

Applies to: `Event`, `Effect`, `LiveEdgeSample`

- `endRealized(userIsScrolledAway:)` carries the flag at the moment the end
  row appeared.
- `explicitClaim` (Go to End, or the user's own message) cancels only the
  recovery; the request's `followRequested` follows.
- `followCancelledByGesture`: a gesture took over from whichever owner and
  armed recovery there is.
- `followDue(_:execute:)`: the debounce elapsed; `execute` is
  `ConversationTranscriptScrollPolicy.shouldExecuteFollow`.
- `followRequested(forced:)` is sent by the view's `scrollToBottom`, after the
  view's own refusals (the takeover latch, the rate limit).
- `recoveryPagedUp(_:mayFollowBack:)`: the page up has had time to realize
  rows; `mayFollowBack` is
  `ConversationTranscriptScrollPolicy.unrealizedEndRecoveryMayFollowBack`.
- `recoveryStep`: one intermediate poll of the recovery loop.
- `LiveEdgeSample` is the gesture state that a replayed edge reads: `live` is
  the state when the effect executes, `sampled` the state when the event was
  sent.
- `recordRecoveryOutcome` records how the recovery ended, with the
  corrections it spent. Every terminal is recorded, whether a correction was
  spent or not.
- `replayLiveEdge` applies the live distance as a geometry edge with the
  sampled gesture state.
- `showGoToEnd` flags the viewport as scrolled away without issuing a scroll
  over it.

### 5. Transition rules

Applies to: the private per-event functions of `ConversationTranscriptRecoveryLifecycle`

- `endDerealized`: a recovery that is already polling keeps its budget. It
  reads the end row's state at every poll, so re-arming would only reset the
  bound.
- `followRequested`: an automatic follow never preempts a forced follow. When
  a recovery owns, the follow takes the viewport; the recovery keeps polling,
  settles until the follow drains, and then owns again. A replacing follow
  inherits the give-up that it must discharge.
- `followFinished`: the correction the follow took the viewport from owns
  again. The replayed edge reads `isFollowing`, and its pending follow back is
  granted as it would have been. When the follow executed but drained onto an
  end row that is still unrealized, the row was already unrealized when the
  follow claimed the viewport and no new edge will come. The recovery is then
  re-armed from the level.
- `recoveryPagedUp`: the follow back re-checks the claim once the rows have
  realized, instead of scrolling over a follow that took the viewport
  meanwhile. A current recovery demoted under that follow still reports its
  yield.
- `recoveryFinished` with `giveUp`: the budget is spent over a row that is
  still unrealized. A re-pin from the live edge would scroll blind to a row
  that is not there, so Go to End is shown. With a follow owning the viewport,
  the give-up is transferred to that follow's terminal instead, because
  flagging the viewport away now would cancel the follow as a takeover.
- `claimViewport`: a correction claims the viewport unless a follow owns it.
  The step function settles under a follow, and the reducer refuses too.

### 6. Follow bookkeeping in the scroll state

Applies to: `ConversationTranscriptScrollState`

- `pastEndRePinTask` is the pending re-check of a viewport that read past the
  end of the content.
- `containerRePinTask` is the pending settle re-check of a container re-pin
  that was deferred while the user was interacting with the scroll view.
- `bottomBandRePinTask` is the pending settle re-check of a pinned viewport
  that a geometry edge (or the end of streaming) read within the at-bottom
  band (#346).
- `isUserScrollPhase` is true while SwiftUI reports a user-driven scroll phase
  (tracking, interacting, decelerating). It is read next to the `UIScrollView`
  flags when a geometry edge decides whether it came from a gesture. An
  explicit follow request (Go to End, the user's own message) clears it,
  because it takes the viewport from the gesture: the phase end that follows
  belongs to the request, not to the gesture's final sample.
- `forcedFollowTakenOverByGesture` latches when a gesture takes over a pending
  forced follow. While it is set, content-raised forced follows are refused
  (`ConversationTranscriptScrollPolicy.forcedFollowTakeoverLatch`).
- `goToEndRequested` is set by the Go to End tap for the `userIsScrolledAway`
  change handler to consume. It is separate from `isScrollingToBottom`, so a
  geometry edge that clears the flag during a forced follow does not queue
  another follow.
- `lastFollowToBottomAt` is the uptime of the last follow-to-bottom request.
  It rate-limits streaming follows.

### 7. Demo diagnostics

Applies to: `lastForcedFollowOutcome`, `lastForcedFollowCorrections`, `lastUnrealizedEndRecoveryReport`, `unrealizedEndRecoveryEpisodes`, `unrealizedEndRecoveryCorrections`, `demoEndDerealization`, `demoEndDerealizationTriggered`, `demoRecoveryResize`

- `lastForcedFollowOutcome` records how the last forced follow ended
  (`landed`, `giveUp`, `yieldToUser`); it is nil while one is in flight or
  before the first. Under `--demo-data` it is read into the transcript's
  accessibility value, so the XCUITests can tell a landed follow from one that
  gave up with the pin kept (#304, #305). `lastForcedFollowCorrections` counts
  the corrections (scroll again, clamp) that it spent.
- `lastUnrealizedEndRecoveryReport` records how the last unrealized-end
  recovery episode ended (#338). It is recorded on every terminal path
  (resolved, given up, yielded, cancelled) with the end row's realization at
  that moment, and is nil while an episode is in flight or before the first.
  `unrealizedEndRecoveryEpisodes` counts the episodes armed on this
  transcript. `unrealizedEndRecoveryCorrections` counts the corrections of the
  in-flight (or last) episode, published as each one is issued so a
  cancellation records them.
- `demoEndDerealization` exists only in Debug, for
  `--demo-end-derealization-trigger-file`. While it is set, the end row is
  withdrawn from the lazy stack, so its real `onDisappear` armed the recovery.
  It keeps the live offset at withdrawal, which the restore is judged against
  (`DemoFixtures.shouldRestoreDerealizedEnd`). It is never set outside
  `--demo-data`. `demoEndDerealizationTriggered` is set once the trigger has
  fired, so a re-run of the poll does not withdraw the row again.
- `demoRecoveryResize` is a content-free receipt for the opt-in
  footer/recovery overlap control.
