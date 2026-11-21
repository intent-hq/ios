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

6. **Wake attributions.** The daemon tags user-role rows delivered by a wake. The tag is on the row's `metadata` and on the persisted text block's `messageMetadata`; hook and PR-monitor tags are also on queued entries. The app checks the row first, then the blocks, so older rows that miss one surface still render.
   1. **Event wakes** (`event_notification`, FE parity: `EventWakeupBanner.svelte`, `ChatPanel.svelte`): `{ eventCount, eventTypes, events? }`. A missing count falls back to the length of `events` or `eventTypes`. Legacy rows without metadata, but with the machine-text prefix, get an empty attribution, so the banner replaces the raw text (FE `isEventWakeMessage`).
   2. Event labels: agent lifecycle events name the agent when the payload has a usable `agentName` or `name`. A value shaped like an agent id (`agent-<uuid>`) is never a display name (FE `resolveAgentName`, without the live session lookup). Other events map to category labels by ordered prefix (FE `EVENT_CATEGORY_LABELS`). An unmapped type is humanized (`custom:thing` → "Custom thing"), so machine ids never show (FE `getActivityLabel`). The summary keeps event order and shares one name across consecutive actions of one agent.
   3. **Hook wakes** (`hook_wake`, PROTOCOL §5.40, FE parity: `hook-wake-attribution.ts`): `{ hookId, hookName, reason, hookStillActive? }`. `rawName` is the verbatim hook name, as used in the literal prefix `[Background hook "<name>"] `. The display strip removes the exact prefix built from `rawName` first, because quotes or edge whitespace in a name defeat the regex; the regex is the fallback. The trailing `[This hook …]` state note is also stripped, because the header shows the state. `hookStillActive` is additive and presence-detected: on a dispatched wake it says re-armed or retired. An eviction always shows retired. Otherwise the label is "woke the agent".
   4. **PR-monitor wakes** (`pr_monitor_wake`, PROTOCOL §5.42, FE parity: `pr-monitor-wake-attribution.ts`): `{ monitorId, repo, prNumber, reason, url? }`. `repo` and `prNumber` are required to build the link. The link is metadata `url`, else the GitHub URL from `repo` and `prNumber` (as `MonitoredPrsRow`). The chip is `#N`, with `owner/repo: ` only when the repo differs from the workspace repository. The `[PR monitor <owner/repo>#<n>] ` prefix is stripped for display.
   5. **Script-monitor wakes** (`script_monitor_wake`, FE parity: `script-monitor-wake-attribution.ts`): `{ source: "system", monitorId, workspaceId, scriptId, runId, scriptName, reason, trigger? }`. Only the metadata attributes a row; script output never supplies a text prefix. `matchedLine` is untrusted script output.
   6. Display strips never change the stored message text.
7. **Model-change notices** (`model_changed`, `agent.setModel`, PROTOCOL §5.5, FE parity: `model-change-notice.ts`).
   1. When a turn starts under a different model or provider than the last committed turn, intentd persists a transcript-only system row `{ from, to, fromProvider, toProvider }`. `from` and `to` are raw model ids; nil means the provider default model. The row is never replayed to providers.
   2. Detection uses only `metadata.type`, so the client tolerates the exact role.
   3. The label is "Switched from <side> to <side>". A side is `<modelId> (<provider name>)`, `<provider name> default model`, or the bare model id. This is simpler than the FE, because iOS has no model catalog for pretty names. When a side cannot be described, the row text is used, then "Model changed".
8. **Questions-dismissed notices** (`questions_dismissed`, `agent.dismissQuestions`, FE parity: `questions-dismissed-notice.ts`). intentd delivers a system-origin message tagged `{ source: "system", dismissedQuestionsMessageId }`. It renders as a divider chip, not a user bubble. Detection reads row `metadata`, then block `messageMetadata`, and tolerates the role.
9. **Turn failures** (`TurnFailureSummary`).
   1. The category is inferred on the client from the reason text, using the markers intentd uses in `crates/intent-acp/src/error.rs`. Structured hints win. Otherwise only intentd's phrasings count, so generic "limit reached", "quota" or tool "timeout" text stays generic.
   2. The summary is total: any input gives a summary, and the original text is kept verbatim in `rawDetails`.
   3. Wrapper prefixes (`internal error:`, `session/prompt failed:`, `JSON-RPC error -NNNNN:`) are peeled repeatedly. The human text comes from `message`, `details`, `detail`, `reason` or a string `error` (breadth-first, top level wins), then `error.type`, then a top-level `type` other than `error`.
   4. The retry hint is the provider's own reset phrase. It ends at a sentence-ending period, `·`, newline or the end; `a.m.`/`p.m.` do not end it. A "try again …" phrase counts only when it names a time or date.
10. **New-messages divider** (FE parity: `new-messages-divider.ts`).
    1. The daemon keeps a per-session `lastSeenMessageId` (PROTOCOL §5.5, `agent.markSeen`). On entry (the `chat.subscribe` seq-0 snapshot) the view model derives the anchor once (`resolveAnchor`) and latches it. Later marker changes never move the divider.
    2. No divider when there is no marker, the marker is the newest message, or the marker id is not in the transcript (for example after `agent.editAndRegenerate`).
    3. A latched nil means "entered, no divider" for the rest of the session. It differs from not latched (`NewMessagesDividerLatch`). A latched anchor that leaves the transcript hides the divider; it is not derived again.
    4. After the entry scroll settles, follow-to-bottom stays on when the distance to the bottom is within the at-bottom threshold (50). A larger distance, or an unknown distance, disables follow, so a later follow cannot pull the user off unread rows (`followDisabledAfterEntryScroll`).
    5. When `agent.markSeen` fires (added from `ConversationViewModelSeenTests` comments): entry never marks seen, so the divider anchor survives. A finished turn marks seen after a short debounce, only while the conversation is on screen (`conversationAppeared()`) and the app is active. A send marks seen only on success, like the desktop: composing is proof of looking, but a failed send delivered nothing. `conversationDisappeared()` marks seen at once and cancels the debounce, so a row that lands later is not marked. Every trigger goes through the store's dedupe against the current marker.

## Consequences

- A new daemon row kind renders as an ordinary or generic row until the app learns it.
- Classification changes must match the desktop files named above.

## Code

- `AgentMessageAttribution`: `from(_:)`, `headerName`, `stripSenderHeader(_:attribution:)`, `senderHeaderPattern`; `ConversationMessage.agentMessageAttribution`
- `AttentionNotice`, `AttentionNoticeKind`; `ConversationMessage.attentionNotice`, `joinedTextContent`
- `QueuedMessage`: `isUserMessage`
- `ContextMention`: `segments(from:)`, `replacingTokensWithTitles(in:)`, `mention(fromPayload:)`
- `EventWakeAttribution`: `from(_:)`, `summaryLabel`, `activityLabel(for:)`, `looksLikeAgentId(_:)`; `ConversationMessage.eventWakeAttribution`
- `HookWakeAttribution`: `rawName`, `postWakeState`, `stateLabel`, `stripPrefix(_:attribution:)`, `stripStateNote(_:)`, `displayText(_:attribution:)`; `ConversationMessage.hookWakeAttribution`
- `PrMonitorWakeAttribution`: `from(_:)`, `resolvedUrl`, `chipLabel(workspaceRepo:)`, `stripPrefix(_:)`; `ConversationMessage.prMonitorWakeAttribution`
- `ScriptMonitorWakeAttribution`: `matchedLine`; `ConversationMessage.scriptMonitorWakeAttribution`
- `ModelChangeNotice`: `label(fallbackText:)`, `fallbackLabel`; `ConversationMessage.modelChangeNotice`
- `QuestionsDismissedNotice`; `ConversationMessage.questionsDismissedNotice`
- `TurnFailureSummary`, `TurnFailureCategory`: `peelWrappers(_:)`, `classify(reason:hints:)`, `retryHint(in:)`; `AttentionNotice.turnFailureSummary`
- `NewMessagesDivider`: `resolveAnchor`, `resolveLatchedAnchor`, `followDisabledAfterEntryScroll`; `NewMessagesDividerLatch`
