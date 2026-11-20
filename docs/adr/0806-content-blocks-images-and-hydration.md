# ADR-0806: Content blocks re-render only on their own changes and hydrate slim media on demand

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ContentBlockView`, `ContentBlockBody` (`Intent/Views/Conversation/Content/ContentBlockView.swift`), `ImageAttachmentThumbnail` (`Intent/Views/Conversation/Content/ImageAttachmentThumbnail.swift`), `AttachmentReferenceImageView` (`Intent/Views/Conversation/Content/AttachmentReferenceImageView.swift`), `AttachmentReferenceVideoView` (`Intent/Views/Conversation/Content/AttachmentReferenceVideoView.swift`), `ImageDecodeFailureView` (`Intent/Views/Conversation/Content/ImageDecodeFailureView.swift`)

## Context

An assistant message renders as a list of content blocks. The message streams,
so it is evaluated often. The daemon's slim projection (PROTOCOL §5.5) can
truncate a block's input, output or image bytes; the app fetches the full block
on demand with `agent.getMessageBlock`. Image blocks can also be attachment
references with no inline bytes.

## Decisions

### 1. The block body is value-compared and ignores closures

Applies to: `ContentBlockView`, `ContentBlockBody.==`

`ContentBlockView` is a thin shell over `ContentBlockBody`. The message hands
every block fresh closures on each evaluation, so the body is gated by
`.equatable()`. It re-renders only when its own block, paired tool result,
workspace, or hydration flag changed, not when a streaming delta lands on a
sibling. The manual `==` excludes closures on purpose: the message builds new
ones per evaluation, and they only capture stable identifiers.

### 2. Tool results are paired once per message

Applies to: `ContentBlockView.toolResult`, `ContentBlockBody.body`

`toolResult` is the `tool_result` paired with a `tool_use` block, paired once
per message by `AssistantMessageView`. It is nil for every other block type. A
standalone `tool_result` block renders nothing, because `ToolCallView` renders
it through the pairing.

### 3. Hydration inputs

Applies to: `ContentBlockView.isHydrating`, `ContentBlockView.onHydrateBlock`, `ContentBlockBody.body` (`toolUse` case)

1. `isHydrating` is true while this block, or its paired result, has an
   `agent.getMessageBlock` hydration fetch in flight (slim projection,
   PROTOCOL §5.5).
2. `onHydrateBlock` fetches the full body of a slim-truncated block by id. When
   it is absent there is no hydration, and bounded previews stay.
3. A tool call row hydrates whichever side was truncated. Input and output are
   separate persisted blocks.

### 4. Image block rendering paths

Applies to: `ContentBlockBody.imageView`, `ContentBlockBody.imageNeedsHydration`, `ImageAttachmentThumbnail`

1. An attachment-reference block (PROTOCOL §5.5) has no inline bytes. The view
   resolves the registry row and fetches the bytes with `file.readChunk`, from
   the workspace's attachment store, through `AttachmentReferenceImageView`.
   `ImageAttachmentThumbnail` does the same for user-attached images.
   `ImageAttachmentThumbnail` is the square rounded thumbnail for a
   user-attached image block; tapping opens the fullscreen lightbox (FE
   parity: `ChatMessage.svelte` attached images).
2. A decodable block is the full image, or the write-time thumbnail served by
   the slim projection (`dataIsThumbnail`). Tapping a thumbnail hydrates.
3. A slim-truncated image asks for the original on tap. The lightbox opens once
   hydration swaps the full block in; the truncation flag then disappears from
   the merged block.
4. A slim row with no persisted thumbnail (legacy rows, failed generation)
   shows a placeholder chip with the same on-demand fetch.

### 5. A pending lightbox opens only when hydration succeeds

Applies to: `ContentBlockBody.lightboxPendingHydration`

The flag is set when a thumbnail tap started hydration. The lightbox then opens
automatically once the full block merges in (`dataTruncated` clears). When the
fetch settles without clearing the flag (a failure), the pending open is
dropped, so a later unrelated merge cannot open the lightbox by surprise.

### 6. A slim-truncated image has no context menu

Applies to: `ContentBlockBody.imageView` (`contextMenu`)

A slim-truncated block only carries the low-resolution preview thumbnail.
Save and Copy there would export it as if it were the full image, and the info
rows would describe the preview. The menu is suppressed. Tapping hydrates the
full block, whose lightbox ellipsis menu offers the actions.

### 7. Copy text matches rendered text

Applies to: `ContentBlockView.stripSuggestedPrompts(_:)`

The function is also used by the whole-message copy
(`MessageBlockPartitioning.assistantCopyText(from:)`), so the copied text
matches the rendered text: suggested-prompts blocks, HTML comments,
`<agent_digest>` and supervisor tags are all removed.

1. Only well-formed suggested-prompts blocks are removed. Body text that only
   looks like one is left intact (see `SuggestedPrompts`).
2. Other HTML comments are removed. Suggested-prompts openers (which end their
   line) are excluded from that pattern, so a malformed one cannot lazily
   capture body text up to an embedded `-->` (for example a Mermaid edge).

### 8. Resource blocks and link routing

Applies to: `ContentBlockBody.body` (`resource` case), `ContentBlockBody.TextURLRoute`, `ContentBlockBody.textURLRoute(for:workspaceId:)`

1. Action proposals render inline. Question resources stay wizard-only.
2. `textURLRoute` is shared by ordinary transcript markdown and the chief
   workspace's linked text. Workspace file links open in the matching viewer,
   whether they are written as `intent://local/file/…` links or as paths
   (`report.html`, `/…/report.html`, `file://…`).
3. `TextURLRoute.unopenable`: iOS cannot open the link, so the row explains why
   instead of ignoring the tap.
4. `TextURLRoute.system` defers to the inherited `openURL` handler, which opens
   tracked pull requests in the app.

### 9. Attachment-reference media views

Applies to: `AttachmentReferenceImageView`, `AttachmentReferenceVideoView`, `ImageDecodeFailureView`

`AttachmentReferenceImageView` renders an attachment-reference image block
(`attachmentId`, no inline `data`). It resolves and fetches asynchronously with
`AttachmentImageLoader`. It shows a loading placeholder, then the image (tap
opens the lightbox), or a tap-to-retry placeholder on failure.

1. `Style.inline` is the assistant-row rendering: the full image with its
   original proportions. `Style.thumbnail` is the user-row attachment grid: a
   small fixed square thumbnail.
2. `loader` is an explicit loader override for tests. When nil, the window
   session's loader is used, then the shared (default-backend) loader. The
   window's `BackendSession` lets pinned windows resolve and fetch attachments
   over their own backend connection.
3. `attempt` is bumped on retry taps, so `.task(id:)` runs the fetch again.
4. `loadedKey` is the workspace|attachment key that `image` was loaded for. If
   view identity is ever reused for a different attachment, the mismatch resets
   the image, so a stale image cannot pass the `image == nil` guard.
5. A `CancellationError` means the view scrolled away mid-fetch. It is not a
   failure.

`AttachmentReferenceVideoView` shows a user-attached video: a poster until
tapped, a retry for failed fetches, or the caller's file chip when the format
cannot be played. Shared cached fetches can finish after SwiftUI cancels the
row's task, so the view checks cancellation before it stores the result.
Scrolling away is not a failed download.

`ImageDecodeFailureView` is the decode-failure fallback shared by inline images
and attachment thumbnails.
