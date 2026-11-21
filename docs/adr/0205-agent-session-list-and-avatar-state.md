# ADR-0205: Agent sessions follow daemon wire rules, list reads establish absence, and avatar state mirrors the web client

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `AgentSession`, `PendingAttentionRequest`, `AgentAttentionKind`,
  `AgentAvatarState` (`Intent/Models/AgentSession.swift`), `AgentListGroup`,
  `AgentListReadScope`, `AgentDelegatedCounts`, `AgentListState`
  (`Intent/Models/AgentListState.swift`), `AgentHistory`
  (`Intent/Models/AgentHistoryEntry.swift`)

## Context

`AgentSession` is the client model of a daemon agent. It is parsed from
`agent.list`, `agent.get` (AgentLite), and `agent.getSession` payloads. The
workspace agent list loads its sections lazily, and the avatar color must match
the web client (cloudlands-fe).

## Decisions

### 1. Wire fields and their absent values

Applies to: `AgentSession.lastMessageRole`, `AgentSession.attentionRequestKind`,
`AgentSession.pendingQuestionsMessageId`, `AgentSession.dismissedQuestionsMessageId`,
`AgentSession.notificationsMuted`, `AgentSession.parentAgentId`

- `lastMessageRole` is the role of the conversation's newest user or assistant
  message: `"user"` or `"assistant"` (PROTOCOL §5.5). It is `nil` when omitted
  (older daemons, or a transcript with neither role).
- `attentionRequestKind`, `attentionRequestReason`, and
  `attentionRequestTimestamp` describe a pending attention request (PROTOCOL
  §5.5 agent attention requests). The kind is `"discussion"` or `"blocker"`. It
  is `nil` when no request is pending. Older daemons never send these fields.
- `pendingQuestionsMessageId` and `dismissedQuestionsMessageId` are the pending
  structured-question markers (PROTOCOL §5.5 "Pending questions"). They are
  lifted under `metadata` on the AgentLite projection. A non-empty
  `pendingQuestionsMessageId` names the assistant message whose questions are
  unanswered. The empty string is the authoritative "nothing pending" clear.
  Legacy marker-less sessions omit both. They have default values so existing
  memberwise construction sites keep compiling.
- `notificationsMuted` is the daemon-owned per-session notification mute
  (PROTOCOL §5.5). A muted agent raises no alert, chime, or haptic on this
  client. It is served top-level on every AgentLite and AgentSession
  projection. Absent (older daemons) means unmuted. It has a default value so
  existing memberwise construction sites keep compiling.
- `parentAgentId` is the canonical direct parent. Creator attribution
  (`createdByAgentId`) is a separate concept.

### 2. The attention-request trio is read from one surface

Applies to: `AgentSession.attentionRequestSurface(_:)`

The trio is top-level on `agent.getSession` and mirrored under `metadata` on
AgentLite (`agent.list`, `agent.get`). Both are absent when no request is
pending (PROTOCOL §5.5). The whole trio is read from whichever surface carries
the kind, so a mixed payload cannot blend fields from the two surfaces.

### 3. Unknown attention kinds are shown as a discussion

Applies to: `AgentAttentionKind.init(wire:)`, `AgentSession.pendingAttentionRequest`

The kind vocabulary is `"discussion"` or `"blocker"` (PROTOCOL §5.5). Unknown
wire kinds fall back to the discussion treatment so newer daemons still surface
an indicator. The reason is collapsed to a one-liner, the same treatment as the
`digest` one-liner surfaces.

### 4. Questions are pending when the pending marker differs from the dismissal marker

Applies to: `AgentSession.hasPendingQuestions`

Questions are pending if and only if the pending marker is set (non-empty) and
differs from the dismissal marker. This is the same derivation the daemon uses
for the workspace `needs_attention` rollup (PROTOCOL §5.5).

### 5. The list preview prefers the newest message and strips markup safely

Applies to: `AgentSession.displayMessage`

Freshness wins (PROTOCOL §5.5). When the user's message is newest, the preview
shows its first line instead of the stale agent response or digest. The daemon
flips `lastMessageRole` to `"assistant"` once mid-turn streamed text is
derivable, so no local turn-state logic is needed.

Only well-formed `<!-- suggested-prompts -->` blocks are stripped, never body
text that only resembles one (see `SuggestedPrompts`). The remaining HTML
comments are stripped, but the pattern excludes suggested-prompts openers
(which end their line), so a malformed opener cannot capture body text up to an
embedded `-->` (for example a Mermaid edge).

### 6. Live previews only override with non-empty values and flip the role with the response

Applies to: `AgentSession.applyingPreview(lastAgentResponse:digest:)`

The method applies the mid-turn preview fields of an enriched
`agent:stream:activity` payload. The daemon stamps `lastAgentResponse` and
`digest` only when they derive to non-empty values, so `nil` inputs keep the
existing values. Applying a live response also flips `lastMessageRole` to
`"assistant"`, which mirrors the daemon's read-path overlay. The role flips with
the response overlay only. A digest-only payload keeps the persisted role, the
same as the daemon, so the agent-side preview resumes once streamed response
text is derivable.

### 7. Avatar state mirrors cloudlands-fe `getAvatarState`

Applies to: `AgentAvatarState.state(for:)` and its private helpers

The state mirrors cloudlands-fe `getAvatarState`
(`agent-avatar/avatar-state.ts`) so both clients color an agent the same way.
A change to `avatar-state.ts` needs the same change here.
Precedence, highest first: completed (unless a turn is running) > failed >
question > attention (blocker or discussion, unless a turn is live) > waiting >
running > idle.

- A completed status yields to live work. A re-woken agent keeps its stale
  `"completed"` status until the turn settles.
- An unanswered question needs a user response even while the agent does
  unrelated work.
- A pending discussion or blocker is suppressed while a turn is live
  (cloudlands `getAgentAttentionRequest`). A re-woken agent that carries a stale
  request renders as running until the turn ends.
- `isTurnLive`: a turn is in flight when there is live-turn evidence on a
  non-terminal status (cloudlands `isAgentTurnLive`). This is narrower than
  `isRunning`: a bare activity status without evidence does not count.
- `isBlockedWaiting`: waiting needs an explicit wait and no live-turn evidence.
  A live turn, or a stale `"waiting"` status with activity flags, stays running.
- `isRunning`: live-turn evidence always counts as running, because a re-woken
  turn overtakes a stale terminal status. A bare activity status counts only
  when the status is not terminal.

### 8. Agent list reads establish absence and never guess orphan membership

Applies to: `AgentListGroup`, `AgentListReadScope`, `AgentDelegatedCounts.orphaned`,
`AgentListState`, `AgentListState.orphanedAgentIds`

`AgentListGroup` is a lazy section of the workspace list. `orphaned` falls back
to the whole delegated bin when the daemon omits `delegatedCounts.orphaned`.
For `AgentDelegatedCounts.orphaned`, absence means the orphan-only read is
unsupported; zero means it is supported.

Successful reads also establish absence. A newer empty whole-bin read must
reject unseen rows from an older, overlapping by-parent response.

An orphan read has authority over its own membership only. An incomplete cache
cannot classify an arbitrary delegated row, so `AgentListReadScope.contains`
returns false for `orphaned` and `retired`. `orphanedAgentIds` is the
authoritative membership from the `orphanedOnly` read. It is never guessed from
an incomplete cache, because background parents may not have been loaded yet.

`AgentListState` holds display state and request bookkeeping for one workspace.
No transcript or detail cache lives in it: all list reads seed
`AgentSummaryStore` separately.

### 9. Agent history keeps titles and drops entries per device

Applies to: `AgentHistory.recording(_:in:limit:)`, `AgentHistory.removing(workspaceId:on:from:)`

`recording` moves the visit to the front. A visit made before the workspace
list loaded keeps the title recorded on an earlier visit. `removing` drops one
device's entries for a workspace that the device reported deleted or archived.
