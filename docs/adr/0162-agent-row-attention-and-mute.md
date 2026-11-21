# ADR-0162: Agent row attention cues and notification mute

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `AgentAttentionKind.color`, `AgentAvatarState.cornerIcon`, `AgentNotificationsMuteButton`, `AgentRowView` (`Intent/Views/Agents/AgentRowView.swift`)

## Decisions

### 1. Attention tints

Applies to: `AgentAttentionKind.color`

A discussion needs input, so it is orange. A blocker is stop-flavored, so it is
red.

### 2. Questions have no corner icon

Applies to: `AgentAvatarState.cornerIcon`

Discussion and blocker states show a corner cue. Questions show no corner icon;
they use the row's status text.

### 3. The notification mute is daemon-owned

Applies to: `AgentNotificationsMuteButton`

The context-menu toggle changes the daemon-owned per-agent notification mute
with `agent.update { changes: { notificationsMuted } }`. The row's containing
list renders it, so it composes with the row's selection button.

### 4. Muting hides attention cues but keeps the running dot

Applies to: `AgentRowView.cornerIcon`

A muted agent shows no corner attention icon. The running dot still shows.
