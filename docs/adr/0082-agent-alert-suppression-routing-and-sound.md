# 0082. Agent alerts: suppression, window routing and sound

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

When an agent goes idle, the app can show a toast, play a sound or haptic, or post a system notification. The user can have several backends, and on iPad and visionOS several windows, each bound to one backend. An alert must reach the right window, must not repeat what the user already sees, and must not sound twice for one event. The window model is in [ADR 0070](0070-backend-bound-windows-and-sessions.md); the visionOS emitter is in [ADR 0044](0044-visionos-window-feedback-sounds.md). This record holds the `NotificationManager` rules.

## Decision

1. **Suppression.**
   1. `shouldSkipIdleEventFastPath(_:)` drops an `agent:idle` event at once for background agents, muted agents (`notificationsMuted: true`, stamped only when set, PROTOCOL §6.5) and agents the daemon marks as waiting on sub-agents.
   2. Then a fresh `agent.list` read decides (desktop parity). It reads every page, so an active agent on a later page still suppresses. A failed read fails open and alerts.
   3. `shouldSuppressIdleAlert(idleAgentId:agents:)` suppresses while the idle agent waits on delegated sub-agents. This is an iOS extension; desktop honors only the emit-time flag. It is safe: the list read can only under-suppress compared with the flag, and an over-suppression heals, because the child's completion wakes the parent and its next idle has the flag cleared.
   4. It also suppresses while another agent is active by `AgentSession.isActive`, so status-only active agents count. Muted agents do not count: mute is per agent, and a muted agent must not keep an unmuted agent's completion silent.
   5. `sourceStillCurrent(_:connectionId:)` drops an event whose source is gone: the default session must still be on the same connection; a pinned session must still be observed.
   6. When the push relay delivers alerts for a connection (`relayDeliversAlerts`), the app posts no local alert. The relay alert reaches `handleForegroundNotification` in the foreground and toasts there.
2. **What the user already sees.**
   1. Suppression is per connection. Only the same backend's open conversation or workspace downgrades the alert to feedback without a toast. The same id open on another backend's window still toasts.
   2. `openAgentIds` and `openWorkspaceIds` are counted per connection, because two windows can show the same conversation; closing one must not end suppression in the other. Opening a conversation also clears the delivered system notification for that agent on that backend only.
3. **Window routing.**
   1. Every alert carries its source backend's connection id, and its taps and presentation belong to that backend's window.
   2. `windowPresentsAlert` and `alertPresents`: on multi-window platforms only the window bound to the source backend shows the alert, feedback and toast alike. If that window is not registered, nothing plays, so the alert cannot replace another backend's visible toast. Single-window platforms always present, as on iPhone.
   3. `selectionRoute`: a tap goes to the registered window of its source backend; else the platform opens or raises that window and holds the tap; on a cold start the tap is held for the first window; a single-window platform showing another backend drops it. Toast taps and system-notification taps share this policy.
   4. One selection handler per backend. A later registration replaces the earlier one. `removeAgentSelectionHandler(for:token:)` removes it only if the token still owns it, so a stale window never removes its successor.
   5. `routeHistorySelection` sends a history tap to an open window for the entry's backend. With none open it opens one where each backend has its own window (visionOS); otherwise it holds the selection and switches this window to the backend.
4. **Sound and haptics.**
   1. `NotificationSoundPolicy` owns every "does this sound play" decision. Call sites never read volume or settings. Scheduled notifications, the visionOS window sound and the attention cue are silent at zero output volume. Foreground banners use the notification sound setting instead, because alert volume is independent of output volume and the volume read can be stale while the app's audio session is inactive.
   2. On iOS, sound goes through local notifications. The toast does not need notification permission. The app removes the system sound from a foreground banner and plays its own chime after the presentation handler returns, so the banner never waits.
   3. On visionOS the global sound is not spatial. The manager publishes a `FeedbackEvent`, and the source backend's window plays the chime from its own scene (`WindowFeedbackSoundEmitter`), so the user hears which window finished. `NotificationChime` synthesizes the WAV once into the temporary directory, because the bundle ships no audio. visionOS has no haptics, so `HapticManager` keeps the call-site API as no-ops.
   4. One agent event often also changes its workspace's attention. The attention cue center plays at most one audible trigger per workspace per event, so the user never hears a double chime.

## Consequences

- Alert tests inject `windowEmitsFeedbackSound`, because they run on the iOS simulator.
- `workspaceStore(for:)` falls back to the default store when the source is not an observed session.

## Code

- `NotificationManager`: `openAgentIds`, `openWorkspaceIds`, `relayDeliversAlerts`, `windowEmitsFeedbackSound`, `FeedbackEvent`, `agentSelectionHandlers`
- `NotificationManager` (aggregation): `shouldSkipIdleEventFastPath(_:)`, `shouldSuppressIdleAlert(idleAgentId:agents:)`, `sourceStillCurrent(_:connectionId:)`, `workspaceStore(for:)`
- `NotificationManager` (presentation): `conversationOpened(agentId:connectionId:)`, `presentForegroundAlert(agentId:workspaceId:agentName:workspaceName:connectionId:)`
- `NotificationManager` (routing): `SelectionRoute`, `selectionRoute`, `windowPresentsAlert`, `alertPresents`, `routeAgentSelection`, `routeHistorySelection`, `removeAgentSelectionHandler(for:token:)`
- `NotificationSoundPolicy`, `LocalNotificationService`, `NotificationChime`, `HapticManager`
