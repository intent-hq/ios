# 0061. Transcript viewport ownership, landing and end-row recovery

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

A lazy stack can report the estimated bottom without realizing its end row (the `scroll-bottom` marker), so the viewport shows a blank band (#338). The transcript recovers by paging up and following back. Forced follows must also confirm that they landed (#281). The view used to coordinate recovery, follows and user takeover with separate flags, and each #350 defect was a handoff that one path forgot.

## Decision

1. **One owner, one reducer.**
   1. `ConversationTranscriptRecoveryLifecycle.transition` is the only way to change `lifecycle`. It is pure: no clock, no task, no budget. The loops keep their deadlines and correction counts and report steps and terminals as events. The view executes the effects in order.
   2. The viewport has exactly one `ViewportOwner`: idle, a follow (from request to terminal), or a recovery (from its first correction to its terminal).
   3. Each follow and recovery gets a token (`FollowToken`, `RecoveryToken`). Every async continuation carries its token. An event whose token is neither the owner nor the armed recovery is stale and returns the state unchanged with no effects.
2. **Follow versus recovery.**
   1. A forced follow is never preempted by an automatic one.
   2. A follow requested during a recovery takes the viewport. The recovery is demoted (`ArmedRecovery.demoted`): it keeps polling, settles while the follow owns, and owns again when the follow drains.
   3. A recovery that is already polling keeps its budget. Re-arming would only reset the bound.
   4. A follow that drains onto a still-unrealized end row re-arms the recovery from the level, because no new edge will come.
   5. A correction claims the viewport only if no follow owns it.
   6. Go to End or the user's own message (`explicitClaim`) cancels only the recovery. The request's own follow comes after.
3. **Recovery steps.**
   1. At rest short of the bottom, try the end target once. At rest at the bottom by geometry with no end row, or after a follow that changed nothing, page up so the stack realizes rows, then follow back. Search farther up after each failed jump; the last bounded attempt realizes the top.
   2. A failed jump can leave the viewport short of the end. Recovery keeps searching there, because it owns the viewport and suppresses other re-pins. Gestures, an explicit reading position and the past-end clamp still win.
   3. A paged-up correction follows back only if nothing claimed the viewport while rows realized: a gesture, a rest the gesture left away, or a follow requested meanwhile. Otherwise it yields.
   4. When the budget or timeout runs out over an unrealized row, recovery does not re-pin blind. It shows Go to End. If a follow owns the viewport, the give-up transfers to that follow (`GiveUpFallback.transferred`), because flagging the viewport away now would cancel the follow as a takeover. Exactly one terminal of that follow discharges the transfer. A follow that replaces it inherits the transfer.
4. **Forced-follow landing (#281, #304, #305).**
   1. `scrollTo` targets the layout at issue time. Rows realized later re-measure, so the viewport can rest short or past the end. A forced follow ends only when live geometry confirms it.
   2. Two identical reads mean the geometry is at rest. Short of the bottom: scroll again. Past the end: clamp. Each has a bounded count. When the bound runs out, the pin stays; no follow ever shows Go to End without a gesture.
   3. Short of the bottom uses `landingTolerance`, not the at-bottom band, so rows under the last message (suggested prompts, the thinking indicator) become visible. Past the end keeps the band.
   4. A gesture in progress, or a flag raised between polls, is the user taking over.
5. **Retained viewport anchor.**
   1. A late new-messages divider can resize an offscreen row. The anchor preserves the first fully visible row's measured offset, or the oversized message that intersects the top, not only its identity.
   2. Each divider revision permits one correction. After that, scrolling belongs to the user. Visible content and gestures win over late entry metadata; the authoritative divider is kept.
   3. SwiftUI owns realization and final placement. The anchor replaces the pending coarse `scrollTo` target instead of writing a native offset, so there is one owner.
   4. The published ownership revision rejects callbacks from before the command. A returned command does not mean the stack applied the alignment, so settling waits for the requested top alignment or the real content boundary.
   5. An explicit follow, a disappearance or a rehost retires captured callbacks. A rehosted view measures afresh.
6. **Observation.** Only ownership changes are published (`viewportOwnershipRevision`); the rest of the reducer's polling state does not redraw the view.
7. **Demo diagnostics.**
   1. Under `--demo-data` the transcript's accessibility value carries `forcedFollowLandingSummary`, for example `lastForcedFollow=landed corrections=1`. The `endRecovery=` part (`UnrealizedEndRecoveryReport.summary`) is appended only after the follow reports, never to the pending report.
   2. `unrealizedEndRecoveryReport` alone decides the reason. `recovered` needs at least one correction and a realized end row at the finish. A cancelled episode overrides its terminal. A `.notNeeded` resolution is `noCorrectionNeeded` with no correction or `unverified` with the row still unrealized.
   3. `demoEndDerealization` withdraws the end row so its real `onDisappear` arms recovery. It is never set outside `--demo-data`.

## Consequences

- Recovery, follows and takeover cannot disagree about who scrolls.
- A new async path must carry a token and go through `transition`.
- Invariants that `TranscriptRecoveryLifecycleTests` asserts on every transition (from test comments): (1) one owner, and only an owner issues a scroll; a demoted recovery exists only under the follow that demoted it; (2) a give-up over an unrealized end row always resolves; (3) the follow a give-up was transferred to discharges it once at its terminal: Go to End if it did not execute over a still-unrealized row, nothing if it executed or the row realized, and an executed drain over an unrealized row re-arms the recovery; a replacing follow inherits the transfer; (4) over an unrealized end row, at-bottom edges clear and re-pin nothing until the row realizes, which replays the live edge; (5) a stale token changes nothing; (6) the reducer keeps no budget, records the terminal's own outcome once, and demoting and restoring a recovery keep its token. Go to End shows at most once, only from a give-up or the terminal it moved to. An inactive transcript has no task owner and no deferred give-up; only end-row realization changes until it appears, and a new visible visit gets fresh tokens.
- The #350 handoff defects (scenarios 1 to 6) are replayed as event sequences through `LifecycleHarness`, which runs the effects against scripted geometry as the view does. Mutation checks: removing `dischargeFallback` from `transition` must fail the transferred give-up sequences, and removing the realization gate (the `isEndRealized` guard in `ConversationTranscriptScrollPolicy.scrolledAwayTransition`, or the `replayLiveEdge` that `endRealized` issues) must fail the blank at-bottom sequence.

## Code

- `ConversationTranscriptRecoveryLifecycle`: `transition`, `State`, `ViewportOwner`, `ArmedRecovery`, `GiveUpFallback`, `FollowToken`, `RecoveryToken`, `Event`, `Effect`, `LiveEdgeSample`, `claimViewport`, `dischargeFallback`, `recoveryPagedUp`
- `ConversationTranscriptScrollPolicy`: `unrealizedEndRecoveryStep`, `unrealizedEndRecoveryMayFollowBack`, `unrealizedEndRecoveryReport`, `UnrealizedEndRecoveryReason`, `followLandingStep`, `FollowLandingTerminal`, `forcedFollowLandingSummary`
- `ConversationTranscriptScrollState`: `lifecycle`, `viewportOwnershipRevision`, `preservePresentedViewport`, `retireViewportRestoration`, `suspendEntryScroll`, `demoEndDerealization`
- `ConversationTranscriptViewportAnchor`: `application`, `cancelRestoration`, `ownershipRevision`
- `DemoFixtures`: `shouldRestoreDerealizedEnd`
