# ADR-0021: Conversation messages and content blocks decode through one lenient path with stable ids

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ContentBlock`, `ResourceContents` (`Intent/Models/ContentBlock.swift`),
  `ContentBlock.FallbackIdentity` (`Intent/Models/ContentBlock+Identity.swift`),
  `ConversationMessage`, `ToolCall`, `ImageBlock`, `QueuedMessage`
  (`Intent/Models/ConversationMessage.swift`), `ConversationSendAttempt`,
  `ConversationSendFileAccess` (`Intent/Models/ConversationSendAttempt.swift`),
  `PendingFile` (`Intent/Models/PendingFile.swift`),
  `ContextMention` (`Intent/Models/ContextMention.swift`)
- Related issues: ios#257, ios#258, monorepo#3338

## Context

Transcript rows arrive as JSON-RPC dictionaries, as delta entities, and from
`agent.getMessageBlock` hydration. SwiftUI keys rows by block id, so a block
must keep the same id across re-decodes. Old daemons and old rows use legacy
field names.

## Decisions

### 1. One decoder per type

Applies to: `ContentBlock.init(from:fallbackIdentity:)`,
`ConversationMessage.init(from:)`, `ConversationMessage.parseMessage(_:)`

Every block decode path (message rows, delta entities, `agent.getMessageBlock`
hydration, `JSONDecoder`) ends in `ContentBlock.init(from:fallbackIdentity:)`.
The paths differ only in the identity that an id-less block falls back to.

`ConversationMessage.init(from:)` is the one message decoder (ios#257).
`parseMessage` routes through it, so the dictionary and `Codable` paths cannot
drift. Array fields are lenient per element: a malformed entry is dropped and
its siblings are kept. A message row without a string `id` is dropped. Id-less
blocks take the daemon's `{messageId}:{index}` identity.

### 2. Id-less blocks get a deterministic fallback id, never a fresh UUID

Applies to: `ContentBlock.FallbackIdentity`, `ContentBlock.contentFingerprint(_:)`,
`ContentBlock.id`

A block gets its `id` from the wire `id`. When the wire omits one (per-item and
batched decodes) it uses a `FallbackIdentity` (ios#257). Only programmatic
creation uses a fresh UUID.

A block decoded as part of a message takes the daemon's own synthetic
`{messageId}:{index}` (PROTOCOL §7.1), so an id-less row keys exactly like a
stamped one. A block decoded on its own is keyed by a deterministic fingerprint
of its content, scoped to its message when known. It is never a fresh UUID:
re-decoding the same payload always yields the same id, so SwiftUI rows survive
re-decodes.

The fingerprint is FNV-1a over the block's identifying fields, with `nil` kept
distinct from empty. It is process-independent, unlike `Hasher`.

### 3. Batch decoding gives the same result per element as single decoding

Applies to: `ContentBlock.decodeBatch(_:fallbackIdentities:)`,
`ConversationMessage.parseMessages(_:)`

Both batch methods exist for ios#258: one serialization and one `JSONDecoder`
for the whole batch instead of one pair per element.

In `decodeBatch`, element `i` decodes with `fallbackIdentities[i]`. The result
keeps one slot per input, `nil` where that element does not decode. When the
batch as a whole cannot be serialized (a non-finite number in one element),
every element is decoded on its own, so the outcome per element is the same
either way.

`parseMessages` does one validation walk for all rows. Rows that do not decode
are dropped, so the result equals `rows.compactMap(parseMessage)`. A page that
cannot be serialized as a whole (a non-finite number in one row) falls back to
per-row parsing, so only the offending row is dropped.

### 4. Legacy field aliases

Applies to: `ContentBlock.content`, `ContentBlock.toolName`,
`ContentBlock.tool_use_id`, `ContentBlock.resolvedMetadata`, `ToolCall.toolName`,
`ToolCall.parameters`

`content` is the legacy alias for `text`. `toolName` is the legacy alias for
`name`. `tool_use_id` and `is_error` are snake_case aliases. `ToolCall` keeps
`toolName` and `parameters` as legacy aliases. `resolvedMetadata` falls back to
the wire `meta` alias that daemon-persisted notice rows use (for example
`meta.kind = "discussion-request"`).

### 5. Wire field meanings on `ContentBlock`

Applies to: `ResourceContents`, `ContentBlock.data`, `ContentBlock.attachmentId`,
`ContentBlock.size`, `ContentBlock.messageMetadata`

- `ResourceContents` holds the nested contents of a standalone `resource` block
  (PROTOCOL §7.1): `{ type: "resource", resource: { uri?, mimeType, text } }`.
  It is decoded leniently. Consumers validate the fields they need (for
  example, question parsing is MIME-gated).
- `data` is base64 encoded.
- `attachmentId` is the attachment-registry reference for placed attachment
  blocks (PROTOCOL §5.5 v6.12). Persisted file and image references carry no
  inline `data`. `size` is the byte length for attachment-reference file
  blocks.
- `messageMetadata` is the per-message send metadata persisted on the delivered
  block (PROTOCOL §5.5), for example the `questions_dismissed` dismissal notice
  tag.

### 6. Slim projection truncation

Applies to: `ContentBlock.inputTruncation`, `inputBytes`, `outputTruncation`,
`outputBytes`, `dataTruncation`, `dataRepresentation`, `dataBytes`,
`ContentBlock.isSlimTruncated`

These flags come from the slim projection (PROTOCOL §5.5, opt-in through
`projection: "slim"`). A served block whose oversized body was replaced by a
bounded preview or thumbnail carries these additive flags. The full body is
fetched on demand through `agent.getMessageBlock`.

- `inputTruncation`: `tool_use.input` was replaced by a bounded preview.
  `inputBytes` is the serialized byte size of the full input.
- `outputTruncation`: `tool_result.output` was replaced by a bounded preview.
  `outputBytes` is the serialized byte size of the full output.
- `dataTruncation`: `image.data` was replaced by a thumbnail, or omitted.
  `dataRepresentation` says whether the present data is the thumbnail.
  `dataBytes` is the byte size of the full image data.

`isSlimTruncated` is true when a `tool_use` or `tool_result` body was reduced to
a bounded preview, or an `image` was reduced to a thumbnail or placeholder.

### 7. Message and queue wire fields

Applies to: `ConversationMessage.appMessageId`, `ConversationMessage.timestamp`,
`ToolCall.status`, `ImageBlock`

- `appMessageId` is the client correlation id that the daemon lifts from row
  metadata (PROTOCOL §5.5).
- `timestamp` is an ISO 8601 string from the server.
- `ToolCall.status` is one of `pending`, `running`, `completed`, `failed`.
- `ImageBlock` accepts either arm the daemon accepts (PROTOCOL §5.5): inline
  base64 `data` (legacy) or an attachment-registry `attachmentId` reference
  (monorepo#3338). `type` is `"image"`. `data` is `nil` for placed references.
  `mimeType` is optional on the reference arm (§5.5). Synthesized `Codable`
  omits `nil` keys, so placed references never carry a `data` key on the wire.

### 8. A queued message is user-authored unless its metadata says otherwise

Applies to: `QueuedMessage.isUserMessage`

Non-user entries carry `messageMetadata` with a string `type`, a non-blank
`fromAgentId`, or `source == "system"` (PROTOCOL §5.5). Absent or malformed
metadata fails open and is treated as user-authored.

The exception is the Q&A wizard's answer message
(`{ type: "question_answers", answeredQuestionsMessageId }`). It is
user-authored despite its tag. It travels through the ordinary send path and
can be auto-queued during the turn-startup race, so it must stay visible in the
queue.

### 9. A send attempt is session-local and retries only proven pre-dispatch failures

Applies to: `ConversationSendAttempt`, `ConversationSendAttempt.canRetry`,
`ConversationSendFileAccess`

A send attempt is session-local recovery, independent of the replaceable
transcript. Its original identity never changes. Selections and placed
references stay owned until delivery is confirmed. It is not a durable outbox
or an idempotency key.

Only a locally proven pre-dispatch failure may be retried, because the daemon
auto-queues duplicate ordinary sends rather than deduplicating them.

`ConversationSendFileAccess` holds extra security-scoped leases owned by the
attempt, not by the changing composer selection.

`PendingFile` (`Intent/Models/PendingFile.swift`) is a file picked from Files
or Photos. It waits in the composer until send time. Security-scoped access is
owned by `ConversationAttachmentPipeline`, not by this value. Its `video` is
retained by every copy, including an in-flight or recoverable send.

### 10. Context mentions mirror the web client parser

Applies to: `ContextMention`

A context mention is decoded from an `@context[...]` token in user-message
text. The parser mirrors the web client's `parseInlineMentions` context branch
(cloudlands-fe `ChatMessage.svelte`). The payload is either base64-encoded JSON
(produced by the TipTap editor's `renderText`) or the legacy pipe-separated
`provider|identifier|title` form.

- `tokenRegex` is equivalent to the web client mention regex's
  `context\[[^\]]+\]` branch. Group 1 is the inner payload.
- `mention(fromPayload:)` treats a payload that starts with `eyJ` (base64 for
  `{"`) as base64-encoded JSON. Malformed base64 or JSON falls back to pipe
  parsing.
- `Payload` is the JSON shape written by the web editor's ContextMention
  `renderText` (`TipTapEditor.svelte`). Only the fields the chip renders are
  decoded.
- `decodeBase64JSON` pads the payload because JavaScript `atob` tolerates
  missing padding and `Data(base64Encoded:)` does not.
- `replacingTokensWithTitles(in:)` serves plain-text surfaces such as clipboard
  copy. It mirrors the web client, which copies chip labels rather than raw
  tokens.
