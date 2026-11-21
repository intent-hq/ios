# 0002. The push relay owns the Live Activity once a machine links

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

The agent Live Activity shows running workspaces on the Lock Screen and in the Dynamic Island. The app can update it only while it runs, in the foreground or in its background grace period. The push relay (`push.intentapp.dev`) can update it at any time through ActivityKit push tokens. Two writers on one activity make the card flicker and show old content.

## Decision

1. **One writer.**
   1. With no linked machine, the app drives every update. After `staleAfter` (30 minutes) without an update, the card is marked stale.
   2. With one or more linked machines, the relay drives the activity. `AgentLiveActivityController` only ends activities when the user turns the switch off.
   3. When the first machine links, the app ends the activity it started, and the relay starts its own with a push-to-start token.
   4. When the last machine unlinks, the app adopts the relay's activity.
2. **Alerts follow the same split.** A linked machine's agent alerts arrive from the relay as remote notifications. The app does not post a local notification for that machine (`deliversAlerts(for:)`).
3. **Launch and foreground.**
   1. The relay's content can be newer than the card while the app was closed. On activation the app reads the relay snapshot and applies it at once.
   2. When the snapshot shows that nothing runs, the app ends any card that the relay's end push did not remove.
   3. The app does not end the activity while backends still connect. An empty result counts only after every backend has loaded its workspaces (`isSettled`).
4. **User dismissal wins.** When the user dismisses the card, the app records the running workspaces. A new card starts only when a different workspace begins to run.
5. **Payload.**
   1. `ContentState.rows` holds only the first running workspaces, so the payload stays small.
   2. `updatedAt` is Unix seconds, so the relay's JSON decodes without a date strategy.
   3. A tap on a row opens `intent://agent?…` and goes through the same routing as a tapped notification (`AgentActivityLink`).
6. **Linking.** The app links each connected machine once while Live Activities are on. A machine that cannot link (an older intentd) is not asked again until the app becomes active again.

## Consequences

- Code that writes the activity must check `isRelayDriven` first.
- A relay outage freezes the card for linked machines. The stale date still applies.

## Code

- `AgentLiveActivityController`: `setRelayDriven(_:)`, `setEnabled(_:)`, `dismissedRunningKeys`, `isSettled`, `staleAfter`
- `PushRelayController`: `deliversAlerts(for:)`, `applySnapshot()`, `declined`, `becameActive()`
- `RelayLinkState`: `isRelayDriven`, `shouldLink(connectionId:enabled:connected:declined:)`
- `AgentActivityAttributes.ContentState`, `AgentActivityLink`
