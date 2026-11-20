# 0053. Agent session wire fields and display state

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

`AgentSession` is the app's view of one agent from `agent.list`, `agent.get` and `agent.getSession`. Rows, avatars and previews read display state from it. The desktop client (cloudlands-fe) shows the same agents, so both clients must derive the same state from the same fields. Older daemons omit many of the fields.

## Decision

1. **Wire fields (PROTOCOL §5.5).**
   1. `lastMessageRole` is the role of the newest user or assistant message: `user` or `assistant`. It is nil on older daemons and on a transcript with neither role.
   2. `attentionRequestKind` is `discussion` or `blocker`, nil when no request is pending. Older daemons never send it.
   3. The attention-request trio is top-level on `agent.getSession` and mirrored under `metadata` on `AgentLite` (`agent.list`, `agent.get`). The whole trio is read from the surface that carries the kind, so a mixed payload cannot blend fields from two surfaces (`attentionRequestSurface`).
   4. `pendingQuestionsMessageId` is lifted from `metadata` on `AgentLite`. A non-empty value names the assistant message whose questions are unanswered. The empty string is the authoritative "nothing pending" clear. Sessions without markers omit it.
   5. `notificationsMuted` is a daemon-owned per-session mute, top-level on every projection. A muted agent raises no alert, chime or haptic on this client. Absent means unmuted.
2. **Derived state.**
   1. Questions are pending when the pending marker is non-empty and differs from the dismissal marker. The daemon uses the same rule for the workspace `needs_attention` rollup (`hasPendingQuestions`).
   2. An unknown attention kind gets the discussion treatment, so newer daemons still show an indicator (`AgentAttentionKind`).
3. **Preview text (`displayMessage`).**
   1. Freshness wins: when the user's message is newest, the preview is its first line, not the older agent response or digest. The daemon flips `lastMessageRole` to `assistant` once streamed text is derivable, so the app has no turn-state logic for this.
   2. A malformed suggested-prompts opener must not hide body text up to a later `-->` (for example a Mermaid edge). Only well-formed suggested-prompts blocks are stripped, and the generic HTML-comment strip skips openers that end their line.
   3. `applyingPreview(lastAgentResponse:digest:)` applies an enriched `agent:stream:activity` payload. Nil inputs keep the existing values. A live response also flips `lastMessageRole` to `assistant`, like the daemon's read-path overlay. A digest-only payload keeps the persisted role.
4. **Avatar state.** `AgentAvatarState` mirrors cloudlands-fe `getAvatarState` (`avatar-state.ts`). Precedence, highest first:
   1. Completed, unless a turn is running. A re-woken agent keeps its old `completed` status until the turn settles.
   2. Failed.
   3. Question. An unanswered question needs the user even while the agent does other work.
   4. Attention (blocker or discussion), unless a turn is live (cloudlands `getAgentAttentionRequest`). A re-woken agent with an old request shows as running until the turn ends.
   5. Waiting. It needs an explicit wait and no live-turn evidence. A live turn, or an old `waiting` status with activity flags, stays running.
   6. Running. Live-turn evidence always counts, also over an old terminal status. A bare activity status counts only on a non-terminal status.
   7. Idle.
5. **Live turn.** A turn is live when there is live-turn evidence on a non-terminal status (cloudlands `isAgentTurnLive`). This is narrower than running: a bare activity status is not enough.

## Consequences

- Display rules change together with the desktop client. A change to `avatar-state.ts` needs the same change here.
- Rows from older daemons show fewer cues but never fail to decode.

## Code

- `AgentSession`: `lastMessageRole`, `attentionRequestKind`, `pendingQuestionsMessageId`, `notificationsMuted`, `displayMessage`, `hasPendingQuestions`, `pendingAttentionRequest`, `applyingPreview(lastAgentResponse:digest:)`, `parseAgent(_:)`, `attentionRequestSurface(_:)`
- `PendingAttentionRequest`, `AgentAttentionKind`
- `AgentAvatarState`: `state(for:)`, `needsUser`, `isTurnLive(_:)`, `isBlockedWaiting(_:)`, `isRunning(_:)`
