# ADR-1305: Agent alerts are scoped to their source backend and window

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `NotificationManager`, `ToastInfo` (`Intent/Utils/NotificationManager.swift`),
  `NotificationManager` aggregation (`Intent/Utils/NotificationManager+Aggregation.swift`),
  `NotificationManager` presentation (`Intent/Utils/NotificationManager+Presentation.swift`),
  `NotificationManager` routing (`Intent/Utils/NotificationManager+Routing.swift`)

## Context

Several backends can be connected at once, and on iPad and visionOS each backend
can have its own window ("window model v2"). An agent that goes idle produces an
alert: feedback (sound or haptic), a toast, or a system notification. The alert
must reach the right window and must not be suppressed or shown by an unrelated
backend's window.

## Decisions

### 1. Every alert has a concrete source backend

Applies to: `ToastInfo.sourceBackendID`, `NotificationManager.selectionRoute(source:registeredBackends:supportsMultipleWindows:)`

Under window model v2 every alert carries its source backend's connection id, so
a tap can route to that backend's window. The tap belongs to that window.

### 2. Sessions are observed for cross-window aggregation

Applies to: `attachSessionObserver(for:)`, `detachSessionObserver(for:)`,
`sourceStillCurrent(_:connectionId:)`

`attachSessionObserver` observes a backend session's connection so its agents
alert too. It is wired to `BackendSessionRegistry.onSessionCreated`. Attaching a
transient pairing session (no backend) or an already-observed backend is a
no-op. `detachSessionObserver` is wired to `BackendSessionRegistry.onSessionTeardown`;
extra detaches are no-ops.

An event's source is still live when the default session is still on the same
active connection, or when a pinned session is still observed (not torn down
mid-flight).

### 3. Idle alerts use a fast path and then a fresh agent list

Applies to: `handleEvent(_:from:)`, `shouldSkipIdleEventFastPath(_:)`,
`shouldSuppressIdleAlert(idleAgentId:agents:)`, `fetchWorkspaceAgents(workspaceId:from:)`

At emit time, the raw `agent:idle` payload skips background agents, muted agents
(`notificationsMuted: true` is stamped on the event only when set, PROTOCOL
§6.5), and agents the daemon already marks as waiting on sub-agents.

Then a fresh `agent.list` read decides (desktop parity). The alert is suppressed
when the idle agent is still waiting on delegated sub-agents, another agent is
active, or the idle agent is background per metadata or muted. A failed read
fails open: the alert is shown. The read covers every page, so an active agent
on a later page still suppresses the alert. It runs over the event source's own
connection.

The waiting-on-children gate is an iOS extension beyond the desktop port, which
only honors the emit-time flag. It is safe because the list read can only
under-suppress relative to the emit-time flag (a consumed watch clears the
flag), and over-suppression self-heals: the awaited child's completion wakes the
parent, whose next turn emits a fresh `agent:idle` with the flag cleared.

The other-agents gate uses the canonical `AgentSession.isActive` predicate, so
status-only active agents suppress premature completion alerts. Muted agents are
excluded from that gate. Mute is per agent and a muted agent's own idle is
suppressed too, so letting its activity hold back an unmuted agent's completion
would leave the workspace silent.

### 4. Visibility is counted per connection

Applies to: `openAgentIds`, `openWorkspaceIds`, `conversationOpened(agentId:connectionId:)`,
`conversationClosed(agentId:connectionId:)`

Open conversations and workspace details are keyed by their session's connection
id and counted as a multiset. Two windows on the same backend can show the same
conversation, and closing one must not stop suppressing alerts for the surface
still visible in the sibling. Opening a conversation suppresses its toasts and
clears any delivered system notification for the same agent on the same backend,
never another backend's agent with the same id. Because closing is keyed by
(agent, connection), a parent conversation's disappearance never clobbers a
pushed child's visibility or another window's.

### 5. The relay alert replaces the local one

Applies to: `presentIdleAlert(agentId:workspaceId:agentName:connectionId:sourceBackendID:)`,
`relayDeliversAlerts`

When the push relay delivers alerts for a connection, its remote alert stands in
for the local one. In the foreground it reaches `handleForegroundNotification`
and toasts there. iOS owns the sound policy; the toast does not depend on
notification permission.

### 6. Suppression and presentation are scoped by backend and window

Applies to: `presentForegroundAlert(agentId:workspaceId:agentName:workspaceName:connectionId:)`,
`windowPresentsAlert(source:windowBackendID:supportsMultipleWindows:)`,
`alertPresents(source:registeredBackends:supportsMultipleWindows:)`

Suppression is connection-scoped: only the same backend's open conversation or
workspace downgrades its alert to feedback. An identically named id open on
another backend's window still toasts. The toast is tagged with the concrete
source backend. `workspaceStore(for:)` falls back to the default store when the
source is not an observed session (the legacy handler path). When the user views
the alert's workspace, feedback plays without a toast, because the agent list
updates through events and the user sees the change.

Presentation is window-scoped. On multi-window platforms a toast renders only in
the window bound to its source backend; a window on another backend, or a
pairing window with no backend, shows nothing. Feedback plays and the toast is
stored only when the source backend's window is registered, because that is the
one window that would render it; otherwise the alert would be invisible yet
clobber another backend's visible toast. Single-window platforms always present
and render every toast, so iPhone behavior is unchanged.

### 7. visionOS plays feedback from the source window

Applies to: `NotificationManager.FeedbackEvent`, `windowFeedbackEvent`,
`windowEmitsFeedbackSound`, `playFeedback(source:workspaceId:)`

On visionOS the window emits the feedback sound. The global system sound is
non-spatial; emitting from the source window's own view hierarchy lets spatial
audio tell the user which window's workspace finished. visionOS has no haptics
(`HapticManager` no-ops), so routing the sound routes all of the feedback.
`windowEmitsFeedbackSound` is injectable because tests run on the iOS simulator.

The manager publishes a `FeedbackEvent` instead of playing a global sound, and
the source backend's window plays it from within its own scene. Window roots
observe `windowFeedbackEvent` (`WindowFeedbackSoundEmitter` via `RootView`). It
is never set on platforms that use system notification sounds. The fresh `id`
distinguishes back-to-back requests from the same backend. Elsewhere,
`playFeedback` plays haptic feedback; iOS sound goes through local
notifications.

Feedback is deduplicated against the source session's workspace attention cue.
One agent event (idle or blocker) often also flips its workspace's attention,
and both sounds within a second are the "double chime". The cue center
arbitrates so at most one audible trigger plays per workspace per event. This is
a no-op off visionOS, where the cue center never sounds.

### 8. Tap routing is per backend window

Applies to: `agentSelectionHandlers`, `registerAgentSelectionHandler(for:_:)`,
`removeAgentSelectionHandler(for:token:)`, `handleNotificationResponse(_:)`,
`routeAgentSelection(agentId:workspaceId:agentName:connectionId:)`,
`routeHistorySelection(agentId:workspaceId:agentName:connectionId:opensSourceWindow:switchWindow:)`,
`openBackendWindow`, `supportsMultipleWindows`, `pendingAgentSelection`

Selection handlers are keyed by the window's bound backend; there is no global
last-window-wins handler. A later registration for the same backend replaces the
earlier one, because windows sharing a backend navigate it identically. The
registration token lets a disappearing window remove only its own registration,
never a successor's. Registering re-routes a held cold-start tap immediately.

System-notification taps and toast taps share one policy (`routeAgentSelection`):
the tap lands on the source backend's own window, never on whichever window
happened to render it. Delivery goes to the registered window. Where multiple
windows are supported the window is opened or raised, and delivery completes
when it registers. A cold-start tap is held for the first window. Cross-backend
taps are dropped on single-window platforms, the same visible behavior as the
old coordinator-side connection guard. `pendingAgentSelection` holds a tapped
alert until its source backend's window registers a handler (cold start, or a
just-opened window still binding).

`openBackendWindow` opens or raises the window bound to a backend through
`openWindow(value:)`. Window roots set it where multiple windows are supported.
Window roots also set `supportsMultipleWindows` (visionOS, iPad) from
`\.supportsMultipleWindows`.

An agent history tap goes to an open window for the entry's backend. With none
open, it opens that backend's window where each backend gets its own
(`opensSourceWindow`, visionOS). Otherwise the selection is held, `switchWindow`
moves this window to the entry's backend, and that backend's window
registration delivers it.
