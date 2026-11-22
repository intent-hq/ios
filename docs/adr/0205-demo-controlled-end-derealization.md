# ADR-0205: Controlled end derealization is trigger-driven and restored on evidence

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `DemoFixtures` end-derealization members (`Intent/Demo/DemoFixtures.swift`)
- Related issues: intent-hq/ios#338

## Context

The transcript recovers when its end row (the `scroll-bottom` marker) is
unrealized by the lazy stack. UI tests need to start that recovery at a chosen
moment and control when the row returns.

## Decisions

### 1. A trigger file withdraws the end row

Applies to: `DemoFixtures.configuredEndDerealizationTriggerFile`,
`DemoFixtures.endDerealizationTriggerFile(from:)`

Once the file exists, the transcript's end row is withdrawn from the lazy
stack. The row's real `onDisappear` then arms the unrealized-end recovery
(`ConversationTranscriptView`) at a moment the UI test chooses, instead of
waiting for the organic hooks-row re-measure. Without
`--demo-end-derealization-trigger-file=<path>` the value is nil and nothing
changes. The last non-empty argument wins. It is gated by a trigger file like
the other fixture gates, because a clock cannot be made robust against a
loaded CI simulator.

### 2. The mode decides what the withdrawn row waits on before it returns

Applies to: `DemoFixtures.EndDerealizationMode`

In `hold`, the row stays withdrawn, so the recovery spends its whole budget and
the give-up path (Go to End) runs. In `release`, the row is restored once the
live scroll view is measurably paged up (the recovery's correction), so its
follow back re-verifies through the row's real `onAppear` and the episode
resolves.

### 3. Restoring the row is evidence-driven

Applies to: `DemoFixtures.shouldRestoreDerealizedEnd(mode:withdrawnOffsetY:contentOffsetY:containerHeight:isInteracting:)`

The restore is never timed and never issued by the recovery itself. In
`.release` the viewport must have moved up by at least half a container: the
recovery's page up, not a re-measure jitter. In every mode, a user gesture that
moves the viewport takes the row back, because the recovery yields to it.
Otherwise the row stays withdrawn.
