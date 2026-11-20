# 0093. Reading agent fields from the daemon

**Status:** Accepted (recorded 2026-11-20 from test comments)

## Context

Agent rows come from several daemon projections (`agent.getSession`, `agent.list`, `agent.get`, live events). The same field can be at the top level or under `metadata`. The app must show the same previews, attention indicators and senders as the desktop.

## Decision

1. **Surfaces.**
   1. `notificationsMuted` is top-level on every `AgentLite` and `AgentSession` projection.
   2. Attention-request fields are top-level on `agent.getSession` and under `metadata` on `AgentLite` (`agent.list`, `agent.get`). The kind, reason and timestamp are read together from the one surface that carries the kind. A reason that is only on the other surface is ignored.
   3. An unknown attention kind from a newer daemon still shows an indicator.
2. **Attention while a turn runs.** As in cloudlands `getAgentAttentionRequest`, live-turn evidence hides a stale request until the turn ends. A bare activity status without evidence is not a live turn.
3. **Preview role.**
   1. `displayMessage` follows `lastMessageRole` (PROTOCOL §5.5).
   2. `applyingPreview` mirrors the daemon's read-path overlay: live agent text flips the role to the assistant. A digest-only payload keeps the stored role.
4. **Hidden suggested-prompts blocks.** A `<!-- suggested-prompts` opener ends its line. A one-line comment that mentions suggested-prompts is stripped like any comment. An embedded `-->` (a Mermaid edge or prose arrow) does not close a block, so body text survives.
5. **Agent-to-agent attribution.** A non-string `fromAgentId` is rejected like a missing one (desktop: `typeof md.fromAgentId === 'string'`).

## Consequences

- Fallbacks for daemons without `lastMessageRole` are tracked in intent-hq/ios#1061.

## Code

- `AgentSession`: `displayMessage`, `applyingPreview`, `pendingAttentionRequest`, `attentionRequestKind`
- `AgentAvatarState`, `AgentMessageAttribution`, `SuggestedPrompts`
- `AgentSessionTests`, `AgentSessionDisplayTests`, `AgentMessageAttributionTests`
