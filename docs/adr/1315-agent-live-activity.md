# ADR-1315: The agent Live Activity

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `AgentActivityRow`, `AgentActivityLink`, `AgentActivityAttributes`
  (`Intent/LiveActivity/AgentActivityAttributes.swift`),
  `AgentActivityContent` (`Intent/LiveActivity/AgentActivityContent.swift`),
  `AgentActivityStyle`, `AgentActivityRowStyle`, `AgentActivityExpandedHeadline`
  (`Intent/LiveActivity/AgentActivityViews.swift`),
  `AgentLiveActivityController` (`Intent/LiveActivity/AgentLiveActivityController.swift`)

## Context

One Live Activity shows the workspaces whose agents are running on every live
backend. The app and the widget extension share the model and the styling. The
push relay (ADR-1316) can drive the activity instead of the app.

## Decisions

### 1. The model is shared and kept small

Applies to: `AgentActivityRow`, `AgentActivityAttributes.ContentState`

`AgentActivityRow` is one running workspace. It is shared by the app, which
publishes it, and the widget extension, which renders it. `agentId` is the agent
a tap opens; it is nil when no agent was reported.

In `ContentState`:

- `rows` holds the first running workspaces, capped so the payload stays small.
- `updatedAt` is Unix seconds, so the push relay's JSON decodes without a date
  strategy.
- `finished` is the agent that just finished; the relay sets it when the last
  one stops.

### 2. Taps use the notification routing

Applies to: `AgentActivityLink`

`intent://agent?...` opens one agent from a Live Activity tap through the same
routing as a tapped notification.

### 3. Content includes only running workspaces

Applies to: `AgentActivityContent`, `AgentActivityContent.Result.runningKeys`

`AgentActivityContent` turns workspace rows from every live backend into Live
Activity content: only workspaces whose agents are running right now.
`runningKeys` holds every running workspace, keyed like `AgentActivityRow.id`.

### 4. Styling

Applies to: `AgentActivityStyle`, `AgentActivityRowStyle`, `AgentActivityExpandedHeadline`

Metrics and colors are shared by the widget extension and the app. Dots and
checks share one column (`markerWidth`) so row titles line up. `running` is the
workspace list's running dot color. Row styles: `finished` is drawn when an agent
finished while others still run (a check, its title and summary); `summary` is
drawn when the last agent finished (its summary under the workspace headline).
The expanded Dynamic Island shows the headline on the leading edge and rows
below.

### 5. The app drives the activity until a machine links to the relay

Applies to: `AgentLiveActivityController`, `AgentLiveActivityController.setRelayDriven(_:)`,
`AgentLiveActivityController.staleAfter`

The controller keeps one Live Activity in step with running agents on every live
backend. The app drives every update, so the activity is current while the app
runs (foreground or its background grace period) and marked stale after. Once a
machine is linked to the push relay, the relay drives it instead, and this
controller only ends activities when the switch turns off.

The relay starts its own activity with push tokens, so an app-started one ends
when the first machine links. The app adopts the relay's activity when the last
machine unlinks.

There is only ever one writer, because two writers on one activity make the card
flicker and show old content. With no linked machine, an app-driven card is
marked stale after `staleAfter` (30 minutes) without an update. Code that writes
the activity checks `isRelayDriven` first. A relay outage freezes the card for
linked machines; the stale date still applies.

### 6. Preference and dismissal

Applies to: `AgentLiveActivityController.enabledKey`, `AgentLiveActivityController.dismissedRunningKeys`,
`AgentLiveActivityController.isSettled`

`enabledKey` is the user preference written by the Settings toggle; it defaults
to on. `dismissedRunningKeys` holds the running workspaces at the moment the user
dismissed the activity; a new activity starts only when another workspace begins
running. `isSettled` is true when every backend has loaded its workspaces, so an
empty result is real rather than a launch still connecting.

### 7. Activities never leave their isolation domain

Applies to: `AgentLiveActivityController` static ActivityKit helpers

Activities are not `Sendable`. Each helper looks one up and uses it without
leaving its own isolation domain.

### 8. Demo state for screenshots

Applies to: `AgentLiveActivityController.demoState(_:)`

In Debug demo mode, `--demo-live-activity-finished` shows the relay's finished
card for screenshots.
