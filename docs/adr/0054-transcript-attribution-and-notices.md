# 0054. Transcript row attribution and notices

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Not every transcript row is a plain user or assistant message. The daemon also writes rows for messages from other agents, attention requests, turn failures and context mentions. It marks them with metadata on the row or on its first content block. The desktop client renders the same rows, and both clients must classify them the same way.

## Decision

1. **Metadata first, graceful fallback.** A row kind comes from its metadata. Absent or malformed metadata gives nil, and the row renders as an ordinary message.
2. **Agent-to-agent messages** (`AgentMessageAttribution`, FE parity: `agent-message-attribution.ts`).
   1. The daemon tags user-role rows sent by another agent with `metadata: { type: "agent_message", fromAgentId, fromAgentName? }`, or `chief_message` for the Assistant. The tag is on the row's `metadata` and on the persisted text block's `messageMetadata`.
   2. A non-empty `fromAgentId` is required.
   3. A `chief_message` comes from the Assistant's own workspace, so its sender id cannot be opened in this workspace.
   4. The app checks the row's `metadata` first, then the text blocks' `messageMetadata`. The FE checks only the row; the block fallback follows the `hookWakeAttribution` precedent as a harmless superset.
   5. `stripSenderHeader(_:attribution:)` removes the `[MESSAGE FROM AGENT {name} ({id})]` header and one blank line, for display only. The exact header rebuilt from metadata (`headerName` is the verbatim `fromAgentName`) wins. A pinned regex covers rows without metadata. Its `(agent-…)` tail keeps a user-written lookalike line intact. Text that does not start with the daemon shape is unchanged (FE parity: `stripAgentMessageHeader`).
3. **Attention notices** (`AttentionNotice`, PROTOCOL §5.5, FE parity: `attention-notice.ts`).
   1. A notice is a system-role row whose first content block has `meta.kind` `discussion-request`, `blocker-report` or `turn-failure`. The first two come from `ws.agent.requestDiscussion` and `ws.agent.reportBlocker`; intentd appends `turn-failure` when a turn ends in a terminal failure.
   2. An unknown kind falls back to the generic system banner.
   3. `ContentBlock.resolvedMetadata` falls back to the wire `meta` key, which these rows use.
4. **User-authored queue entries** (`QueuedMessage.isUserMessage`, PROTOCOL §5.5).
   1. An entry is not user-authored when its `messageMetadata` has a string `type`, a non-blank `fromAgentId`, or `source == "system"`. Absent or malformed metadata fails open: the entry counts as user-authored.
   2. Exception: the Q&A answer (`type: "question_answers"`) is user-authored. It uses the ordinary send path and can be auto-queued during the turn-startup race, so it must stay visible in the queue.
5. **Context mentions** (`ContextMention`, FE parity: `parseInlineMentions` in cloudlands-fe `ChatMessage.svelte`).
   1. A token is `@context[...]`. Its payload is base64 JSON (written by the TipTap editor's `renderText`) or the legacy `provider|identifier|title` form.
   2. A payload that starts with `eyJ` (base64 for `{"`) is read as base64 JSON. Missing padding is accepted, like JS `atob`. Malformed base64 or JSON falls back to the pipe form.
   3. Plain-text surfaces such as clipboard copy replace each token with its title, like the FE copies chip labels.

## Consequences

- A new daemon row kind renders as an ordinary or generic row until the app learns it.
- Classification changes must match the desktop files named above.

## Code

- `AgentMessageAttribution`: `from(_:)`, `headerName`, `stripSenderHeader(_:attribution:)`, `senderHeaderPattern`; `ConversationMessage.agentMessageAttribution`
- `AttentionNotice`, `AttentionNoticeKind`; `ConversationMessage.attentionNotice`, `joinedTextContent`
- `QueuedMessage`: `isUserMessage`
- `ContextMention`: `segments(from:)`, `replacingTokensWithTitles(in:)`, `mention(fromPayload:)`
