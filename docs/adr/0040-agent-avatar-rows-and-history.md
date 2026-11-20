# 0040. Agent avatar, row cues and agent history

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Agent avatars, agent rows and the agent history drawer appear on many screens. They must match the desktop, stay smooth in long lists, and show attention cues that the user can mute.

## Decision

1. **Avatar geometry.**
   1. Workspace rows (`workspaceStyle`) use the iOS artwork. Other surfaces keep the desktop geometry from `avatar-size.ts` "standard": surface 20, art 16, clear space 2, corner radius 6. Sizes scale from these ratios.
   2. `icon` is the specialist icon metadata from PROTOCOL §5.11.
2. **Avatar colors.**
   1. The tile surface follows the desktop `--agent-avatar-surface-*` tokens. Idle is neutral: hsl(145 14% 92%) light, hsl(145 12% 78%) dark.
   2. The glyph is near-black (#080808) in both schemes, because the tile stays light. The completed tile darkens in dark mode, so it has its own foreground token.
3. **Active pulse.**
   1. The pulse animates only the ring's stroke color, in the render server (`AgentAvatarPulse`). It never animates SwiftUI geometry: an implicit `repeatForever` made rings drift between rows when a list reordered. There are no per-frame SwiftUI updates.
   2. The ring reuses SwiftUI's continuous rounded-rectangle path, with its centered stroke.
   3. When the app becomes active, `updatePulse()` reinstalls the animation if backgrounding removed it. A view update never restarts a running pulse.
4. **Row cues and mute.**
   1. The per-agent notification mute is daemon-owned. The toggle sends `agent.update { changes: { notificationsMuted } }`. The containing list renders the toggle in the context menu, so it composes with the row's selection button.
   2. A muted agent hides its attention cues (discussion, blocker) but keeps the running dot.
5. **Agent history drawer.**
   1. The agent history is a global right-edge drawer. It lists visited agents on every saved device. It is the counterpart of the left-edge Connections switcher, and the Connections switcher stands down while it is open (`isAgentHistoryOpen`).
   2. `AgentHistoryList` reads the live stores itself, so store updates re-render only the panel.
   3. The open device's workspace title is read live. Other devices use the title saved with the visit.
   4. The row subtitle is the device, then the agent. When the workspace is unknown, the agent name moves to the title.

## Consequences

- A change to avatar geometry or colors must follow the desktop tokens, or update this record.
- Any new avatar animation must run in the render server, not as SwiftUI state.

## Code

- `AgentAvatarView`: `workspaceStyle`, `icon`, `surfaceColor`, `glyphColor`
- `AgentAvatarPulse`: `updatePulse()`
- `AgentNotificationsMuteButton`
- `AgentHistoryDrawer`, `AgentHistoryList`, `OpenAgentHistoryAction`
