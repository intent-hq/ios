# ADR-0136: Transcript demo instrumentation

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConversationTranscriptView+Demo.swift` (`Intent/Views/Conversation/Transcript/ConversationTranscriptView+Demo.swift`): `transcriptDemoReport`, `unrealizedEndRecoveryDemoReport`, `demoWithdrawnEnd`, `withdrawEndRowForDemo()`, `restoreDerealizedEndIfMoved()`, `View.demoStartupGestureProbe(scrollState:)`, `View.demoAccessibilityValue(_:)`, `View.demoEndDerealization(triggerFile:onTrigger:onGeometryChange:)`; `ConversationTranscriptView+DemoResize.swift` (`Intent/Views/Conversation/Transcript/ConversationTranscriptView+DemoResize.swift`): `ConversationTranscriptScrollState.DemoRecoveryResize`, `demoRecoveryResizeEnabled`, `recordDemoRecoveryResize(from:to:)`, `recordDemoRecoveryResizeFollowBack(_:)`
- Related issues: #338

## Context

UI tests under `--demo-data` need to read the transcript's scroll outcomes and
to force rare states, such as a dropped end row or a footer resize during a
recovery. The instrumentation must not change production behavior.

## Decisions

### 1. The demo report exposes the real state

Applies to: `transcriptDemoReport`, `unrealizedEndRecoveryDemoReport`

A preserved entry has no forced follow to finish. The report keeps that
distinct from a requested follow, and exposes the actual authority and owner
state. The recovery report is the last episode's report. With an episode in
flight (`recovering`) or none armed yet (`notAttempted`), it is the
classifier's reading of the current state.

### 2. Demo surfaces have zero production impact

Applies to: `demoWithdrawnEnd`, `View.demoAccessibilityValue(_:)`,
`View.demoStartupGestureProbe(scrollState:)`, `View.demoEndDerealization(triggerFile:onTrigger:onGeometryChange:)`

1. `demoWithdrawnEnd` is nil outside `--demo-data` without reading the state,
   so production bodies take no dependency on it.
2. `demoAccessibilityValue` exposes the value as the view's accessibility
   value only under `--demo-data`, so XCUITests can read the transcript's
   landing outcome. Otherwise the value is neither computed (so its observed
   state is not a body dependency) nor applied.
3. Only the startup and history demos expose the gesture probe. Its one-point
   overlay does not take part in transcript layout or receive gestures.
4. `demoEndDerealization` is installed only under `--demo-data` with
   `--demo-end-derealization-trigger-file`. It polls for the trigger file and
   calls `onTrigger` once the file exists. It calls `onGeometryChange` on every
   content offset change, so the withdrawn end row can be restored on live
   evidence (#338). Otherwise neither the task nor the observer is installed.

### 3. Controlled end derealization uses the real recovery

Applies to: `withdrawEndRowForDemo()`, `restoreDerealizedEndIfMoved()`

`withdrawEndRowForDemo` withdraws the end row once the trigger file
(`DemoFixtures.configuredEndDerealizationTriggerFile`) exists. The marker
leaves the lazy stack, its real `onDisappear` arms the recovery through the
ordinary `.endDerealized` edge, and the recovery runs unchanged. Nothing it
reads is fabricated. It waits for the live scroll view, so the offset that the
restore is judged against is the one the recovery pages from.

`restoreDerealizedEndIfMoved` puts the row back on evidence from the live
scroll view alone (see `DemoFixtures.shouldRestoreDerealizedEnd`): the
recovery's page up in `release` mode, or a gesture in either mode. Restored at
the end of the content while the viewport rests above it, the marker stays
unrealized until the recovery's own follow back reaches it. Its real
`onAppear` resolves the episode.

### 4. The recovery-resize demo records evidence only

Applies to: `ConversationTranscriptScrollState.DemoRecoveryResize`,
`demoRecoveryResizeEnabled`, `recordDemoRecoveryResize(from:to:)`,
`recordDemoRecoveryResizeFollowBack(_:)`

`DemoRecoveryResize` is a receipt of actual geometry, never an input to
recovery decisions.

1. Only the disposable demo control (`--demo-hooks-row-during-recovery`)
   installs this overlap. The fixture releases the real `hook.list` response
   after the real recovery's page up has moved the live scroll view. It never
   changes recovery timing.
2. The geometry callback is the evidence that the footer really resized the
   container while the same recovery still owned the page up.
3. The follow-back record runs before the lifecycle's follow-back effect. A
   later resize or a different owner cannot earn overlap credit for this
   correction.
