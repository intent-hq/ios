# ADR-0207: Wake and agent-message attribution is metadata-first and never alters stored text

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `AgentMessageAttribution` (`Intent/Models/AgentMessageAttribution.swift`),
  `EventWakeAttribution` (`Intent/Models/EventWakeAttribution.swift`),
  `HookWakeAttribution` (`Intent/Models/HookWakeAttribution.swift`),
  `PrMonitorWakeAttribution` (`Intent/Models/PrMonitorWakeAttribution.swift`),
  `ScriptMonitorWakeAttribution` (`Intent/Models/ScriptMonitorWakeAttribution.swift`)

## Context

The daemon delivers some user-role rows that a person did not type: messages
from another agent, and wakes from event subscriptions, background hooks, PR
monitors, and script monitors. The daemon tags these rows with metadata and
often prepends a machine-text prefix. The transcript shows an attribution
header or banner instead of the raw text. The web client (cloudlands-fe) has
the same feature, and the two clients must agree.

## Decisions

### 1. Shared rules for every attribution

Applies to: every `from(_:)` method and every `ConversationMessage` attribution
property in the files above

- Extraction is metadata-first with graceful fallback. Absent or malformed
  metadata returns `nil`, so the message renders exactly as before.
- The daemon tags the row's `metadata` and the persisted text block's
  `messageMetadata`. The `ConversationMessage` properties check both, so older
  rows that miss one surface still render the header.
- Prefix and header stripping is display-only. The stored message text is never
  mutated. Text that does not match is returned unchanged.

### 2. Agent-to-agent messages

Applies to: `AgentMessageAttribution`, `ConversationMessage.agentMessageAttribution`

The daemon tags user-role rows sent by another agent with
`metadata: { type: "agent_message", fromAgentId, fromAgentName? }`, or
`chief_message` for the Assistant. Malformed metadata means a wrong type or a
missing or blank `fromAgentId`. Web parity: `agent-message-attribution.ts`.

- `Kind.chief` (`chief_message`): the Assistant sent the message from its own
  workspace, so the sender id cannot be opened in this workspace.
- `rawName` is the untruncated sender name ("Agent" fallback). It is used where
  the full name matters, for example titling the pushed sender conversation.
  This follows the `HookWakeAttribution.rawName` precedent.
- `headerName` is the verbatim `fromAgentName` (`nil` when absent), as the
  daemon used it in the literal `[MESSAGE FROM AGENT …]` sender header.
- `stripSenderHeader(_:attribution:)` strips the
  `[MESSAGE FROM AGENT {name} ({id})]` header plus its one blank separator line.
  The exact header rebuilt from the row's metadata wins. The pinned regex
  `senderHeaderPattern` covers rows without it. Its `(agent-…)` tail keeps a
  user-written lookalike line intact. Web parity: `stripAgentMessageHeader`.
- The web client checks only the row metadata for agent messages. The block
  `messageMetadata` fallback here follows this repo's `hookWakeAttribution`
  precedent as a harmless superset.

### 3. Event-subscription wakes

Applies to: `EventWakeAttribution`, `ConversationMessage.eventWakeAttribution`

The daemon tags rows delivered by an event-notification wake with
`{ type: "event_notification", eventCount, eventTypes, events? }`. Web parity:
`EventWakeupBanner.svelte`, and the ChatPanel.svelte event-notification turn
branch for the row lookup.

- `eventCount` falls back to the `events` or `eventTypes` length when the
  daemon omits the count. `eventTypes` are raw types such as `agent:idle` and
  `file:changed`.
- `Event.agentName` is set only when the payload carries a non-id-shaped
  `agentName` or `name` field. Otherwise it is `nil`, so labels fall back to
  generic wording instead of a raw agent id. `looksLikeAgentId(_:)` matches the
  `agent-<uuid>` shape so id values that leak into name fields never render as
  display names. `resolveAgentName` mirrors the web `resolveAgentName`, minus
  the live session-store lookup, which iOS does not keep per message.
- `summaryLabel` preserves event order and shares the name across consecutive
  actions by one agent. It dedupes category labels: two `file:*` events show
  one "File changes".
- `activityLabel(for:)`: agent lifecycle events name the agent when the payload
  carries a usable name. Everything else maps to its category label. Web
  parity: activity-labels and event-wake-summary. `categoryLabels` is the
  ordered prefix mapping from event-wake-summary `EVENT_CATEGORY_LABELS`.
- `humanized(_:)` turns an unmapped wire type into words, so machine
  identifiers never appear verbatim in the banner (web parity:
  `getActivityLabel` default). Example: `custom:thing` becomes "Custom thing".
- Legacy rows carry no metadata, only the `[WORKSPACE EVENTS]` machine-text
  prefix. They get an empty attribution, so the banner with its generic label
  replaces the raw machine text (web parity: `isEventWakeMessage`).

### 4. Background-hook wakes

Applies to: `HookWakeAttribution`, `ConversationMessage.hookWakeAttribution`

The daemon tags rows delivered by a background hook wake (PROTOCOL §5.40) with
`{ type: "hook_wake", hookId, hookName, reason, hookStillActive? }`, on the
row's `metadata`, the persisted text block's `messageMetadata`, and queued
entries' `messageMetadata`. Web parity: `hook-wake-attribution.ts`, and
ChatMessage.svelte for the row lookup.

- `rawName` is the verbatim hook name (empty when absent), untrimmed and
  untruncated, exactly as the daemon used it in the literal wake prefix. It
  builds the exact literal prefix for metadata-first stripping.
- `reason` is `dispatched`, `evicted`, and so on; empty when absent.
- `postWakeState` says whether the hook stays active after a `dispatched` wake
  (perpetual re-arm) or is retired. It is `unreported` on other reasons and on
  messages persisted before the daemon added the field; the field is detected
  by presence.
- `stateLabel`: on dispatched wakes that carry `hookStillActive`, the header
  says whether the hook re-armed or retired. An eviction always retires the
  hook, so its wake always shows the retired suffix. Otherwise the label is the
  plain "woke the agent". Web parity: HookWakeAttributionHeader.
- `stripPrefix(_:attribution:)` removes the literal prefix
  `[Background hook "<name>"] `. When the attribution carries the verbatim hook
  name, it strips the exact literal prefix built from it. This works for names
  that contain double quotes or edge whitespace, which defeat the regex.
  Otherwise it falls back to the regex.
- `stripStateNote(_:)` removes the trailing state note that the daemon appends
  to dispatched and evicted wakes: a final single-line paragraph that starts
  with `[This hook` and ends with `]`. It also matches a note that is the whole
  string. The attribution header conveys the post-fire state instead.

### 5. PR-monitor wakes

Applies to: `PrMonitorWakeAttribution`, `ConversationMessage.prMonitorWakeAttribution`

The daemon tags rows delivered by a centralized PR-monitor wake (PROTOCOL
§5.42) with `{ type: "pr_monitor_wake", monitorId, repo, prNumber, reason, url? }`,
on the row's `metadata`, the persisted text block's `messageMetadata`, and
queued entries' `messageMetadata`. Web parity: `pr-monitor-wake-attribution.ts`,
and ChatMessage.svelte for the row lookup.

- `repo` is `owner/repo`. `from(_:)` requires a usable `repo` and `prNumber`,
  because both are needed to build the PR link.
- `url` is the PR's HTML URL, present when the daemon had a baseline snapshot to
  read it from. `resolvedUrl` falls back to the GitHub URL built from `repo` and
  `prNumber` (the same fallback as MonitoredPrsRow), so the chip works before
  the daemon ships `url`.
- `chipLabel(workspaceRepo:)` follows the MonitoredPrsRow convention: `#N`,
  prefixed with `owner/repo: ` only when the PR's repo differs from the
  workspace repository. When the workspace repository is unknown it is plain
  `#N`.
- `stripPrefix(_:)` removes the literal prefix `[PR monitor <owner/repo>#<n>] `.

### 6. Script-monitor wakes

Applies to: `ScriptMonitorWakeAttribution`

The daemon tags rows delivered by a `ws.script.monitor` watch with
`{ type: "script_monitor_wake", source: "system", monitorId, workspaceId,
scriptId, runId, scriptName, reason, trigger? }`. Only this structured metadata
attributes a row: script output never supplies a text prefix. Malformed metadata
returns `nil`. Web parity: `script-monitor-wake-attribution.ts`.

`matchedLine` is the matched output line for `output-match` wakes. It is
untrusted script output.
