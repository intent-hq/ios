# ADR-0211: Demo fixtures are the UI test contract

**Status:** Accepted (recorded 2026-11-20 from test comments)

## Context

`--demo-data` runs the app against `DemoFixtures` instead of a daemon. UI tests, App Store screenshots and design tests all read these fixtures. A fixture that drifts from the wire shape, or from what a UI test taps, breaks tests far from the cause.

## Decision

1. **Same path as production.** Demo data reaches the stores through the normal subscribe path and the real router and stores. A design test adapter (`DesignFixtureConnection`) only carries transport. It does not implement send, stop, question or monitor behaviour.
2. **Seq-0 snapshot.** The app loads a transcript from the `chat.subscribe` seq-0 snapshot, routed by `agentId`. The long transcript that the scroll UI tests use rides that push. The `agent.getConversation` recovery seek serves the same rows.
3. **Status image.** Exactly one workspace row renders the status thumbnail. The status-image UI test depends on this (intent-hq/intent#3868).
4. **Long conversation shape (intent-hq/ios#304, #305).** The long transcript looks like a coordinator: paired tool calls, agent-to-agent report rows from the delegates the coordinator waits on, thinking blocks, and markdown with fenced code. Row heights vary widely.
5. **Foreground agent.** The delegates are background sub-agents. The coordinator stays the workspace's only foreground agent, so it is the only row the UI tests tap on the overview, while the "Waiting for all" footer still has rows.
6. **Launch-argument gates.**
   1. A trigger file wins over a delay. The last non-empty trigger path wins.
   2. For an enum argument, the last well-formed value wins and unknown values are ignored.
   3. Each gate reads only its own argument.
7. **End derealization (intent-hq/ios#338).** The withdrawn end row comes back only on measured movement of the live scroll view: in `release`, the recovery's page up (half a container is the bar); in any mode, a gesture that moved the viewport. Never at rest, never on a re-measure jitter, and never in `hold` without a gesture.
8. **Slim-truncated tool rows.** Two truncated tool calls sit near the end. In `leading` layout a row opens a text-bearing message, the shape that reproduced intent-hq/ios#338. In `standalone` layout a tool-only assistant message sits before a text message, so no copy-menu overlay claims its taps (intent-hq/ios#344).

## Consequences

- Change a fixture only together with the UI tests that tap it.
- `DemoFixturesTests` fails before a screenshot run when a fixture breaks the wire shape.
- The transcript scroll UI tests that depend on these fixtures: see [0217](0217-transcript-scroll-ui-tests.md).

## Code

- `DemoFixtures`: `subscriptionPush(for:params:)`, `hookListGate(from:)`, `blockHydrationGate(from:)`, `slimToolRowLayout(from:)`, `shouldRestoreDerealizedEnd(mode:withdrawnOffsetY:contentOffsetY:containerHeight:isInteracting:)`, `longConversationTruncatedToolCalls`
- `DemoMode`
