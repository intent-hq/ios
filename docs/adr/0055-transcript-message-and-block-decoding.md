# 0055. Transcript message and block decoding

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Transcript rows arrive as JSON-RPC dictionaries from message pages, delta entities and `agent.getMessageBlock`. Pages can be large, some blocks have no wire `id`, and the daemon can send slim projections that replace big bodies with previews. SwiftUI keys rows by id, so an id that changes between decodes resets row state.

## Decision

1. **One decoder each.**
   1. Every block decode path (message rows, delta entities, `agent.getMessageBlock` hydration, `JSONDecoder`) ends in `ContentBlock.init(from:fallbackIdentity:)`. The paths differ only in the identity an id-less block falls back to.
   2. `ConversationMessage.parseMessage(_:)` routes through `init(from:)` (ios#257), so the dictionary and `Codable` paths cannot drift.
2. **Block identity** (`FallbackIdentity`, ios#257).
   1. A block uses its wire `id`.
   2. A block without one, decoded as part of a message, takes the daemon's own synthetic `{messageId}:{index}` (PROTOCOL §7.1). An id-less row keys exactly like a stamped one.
   3. A block decoded on its own takes a deterministic fingerprint of its content (FNV-1a, process-independent, nil kept distinct from empty), scoped to its message when known.
   4. Decoding never assigns a fresh UUID. Only programmatic creation does.
3. **Lenient arrays.** A malformed array element is dropped and its siblings are kept. A message row without a string `id` is dropped.
4. **Batch decoding** (ios#258). `ConversationMessage.parseMessages(_:)` and `ContentBlock.decodeBatch` use one serialization and one `JSONDecoder` for a whole page. The result equals decoding each element alone. When the batch cannot be serialized as a whole (a non-finite number in one element), each element is decoded alone, so only the bad element is dropped.
5. **Resource blocks** (PROTOCOL §7.1). A standalone `resource` block is `{ type: "resource", resource: { uri?, mimeType, text } }`. It decodes leniently; consumers check the fields they need (question parsing is MIME-gated).
6. **Attachments** (PROTOCOL §5.5 v6.12).
   1. A placed file or image block carries an `attachmentId` reference and no inline `data`; `size` is its byte length.
   2. A queued `ImageBlock` is either inline base64 `data` (legacy) or an `attachmentId` reference (monorepo#3338). Synthesized `Codable` omits nil keys, so a reference never sends a `data` key. `mimeType` is optional on the reference arm.
7. **Slim projections** (PROTOCOL §5.5, opt-in with `projection: "slim"`). A block whose large body was replaced carries additive flags: `inputTruncation`/`inputBytes` for `tool_use` input, `outputTruncation`/`outputBytes` for `tool_result` output, and `dataTruncation`/`dataRepresentation`/`dataBytes` for image data replaced by a thumbnail or omitted. `isSlimTruncated` blocks are hydrated on demand with `agent.getMessageBlock`.
8. **Message metadata.** `messageMetadata` is the per-message send metadata persisted on the delivered block (for example the `questions_dismissed` tag). `appMessageId` is the client correlation id that the daemon lifts from row metadata.

## Consequences

- Re-decoding the same payload always gives the same ids, so rows keep their state.
- A bad element costs only that element, never the page.

## Code

- `ContentBlock`: `init(from:fallbackIdentity:)`, `FallbackIdentity`, `fallbackId(for:fingerprintParts:)`, `decodeBatch`, `contentFingerprint`, `isSlimTruncated`, `messageMetadata`, `resolvedMetadata`, `attachmentId`
- `ResourceContents`, `ProjectionTruncation`, `ImageDataRepresentation`
- `ConversationMessage`: `init(from:)`, `parseMessage(_:)`, `parseMessages(_:)`, `appMessageId`
- `ImageBlock`
