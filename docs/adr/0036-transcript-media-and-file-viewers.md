# 0036. Transcript media and file viewers

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Transcript rows show images, videos and PDFs from three sources: inline base64 image blocks, attachment references (`attachmentId`, no inline bytes, PROTOCOL §5.5), and Markdown links to workspace files, saved assets or the web. The slim transcript projection can truncate a block to a thumbnail, and `agent.getMessageBlock` fetches the full block on demand (hydration). Pinned windows talk to their own backend. Streaming deltas re-render the message many times a second. [ADR 0012](0012-attachment-placement-and-resolution.md) and [ADR 0094](0094-attachment-placement-and-images.md) cover how attachment bytes are resolved and cached.

## Decision

1. **Render cost.** `ContentBlockView` is a thin shell over `ContentBlockBody`, which is `.equatable()`. A block re-renders only when its own block, its paired tool result, the workspace or its hydration flag changes, not when a delta lands on a sibling. The manual `==` leaves out closures on purpose: the message builds new ones on each evaluation, and they capture only stable ids.
2. **Session-bound loading.** Media loads use the window's `BackendSession` when one is in the environment, so pinned windows fetch over their own connection. Saved assets bind to the window's session, never to a backend hint in the URL (`assetMediaFetcher(session:)`). Saved assets use the same session loader, cache and decode limits as files.
3. **Cancellation is not failure.** A row that scrolls away cancels its fetch. `CancellationError` leaves the row without a failure state. A shared cached fetch can finish after SwiftUI cancels the row's task, so the video row checks cancellation again before it stores the result. `loadedKey` resets the loaded image when view identity is reused for another attachment, so a stale image cannot survive.
4. **Hydration.**
   1. A slim-truncated image carries only a low-resolution thumbnail (`dataIsThumbnail`). A tap hydrates it, and the lightbox opens when the full block merges in and the truncation flag clears (`imageNeedsHydration`).
   2. If the fetch settles without clearing the flag (a failure), the pending open is dropped, so a later unrelated merge cannot open the lightbox by surprise.
   3. A truncated image has no Save or Copy menu, because it would export the preview as if it were the full image. The full block's lightbox menu offers the actions.
   4. A slim row without a persisted thumbnail (legacy rows, failed generation) shows a placeholder chip with the same on-demand fetch.
   5. Action proposals render inline. Question resources render only in the wizard.
5. **Image actions.** Save and Copy plus dimensions and file size appear in the thumbnail context menu and the lightbox menu (desktop: chat-image menu; iOS offers Save and Copy instead of Download and Copy path).
   1. Saving uses add-only photo library access (`NSPhotoLibraryAddUsageDescription`).
   2. A denial is kept apart from other failures, so the alert points to Settings only when that helps (`ChatImageSaveOutcome`).
   3. Menu content is torn down when the menu closes, so the alert lives on the view that hosts the menu (`ImageSaveAlertModel`, `imageSaveAlert()`).
   4. User-attached images show as square thumbnails that open the lightbox (desktop: `ChatMessage` attached images). `ImageLightboxView` matches the desktop `ImageLightbox` gestures.
6. **Markdown media routes (`MarkdownImageRoute`).**
   1. Intent-file links and `workspace-asset://` links load through the daemon. Malformed saved-asset URLs are claimed too, so they fail locally instead of reaching Textual's network fallback.
   2. `http` and `https` go to `RemoteImageLoader`. Cleartext `http` is claimed on purpose: ATS allows only local-network http (`NSAllowsLocalNetworking`), such as images the daemon serves at 127.0.0.1. Non-local http fails ATS here and in the fallback loader alike, so nothing is lost.
   3. Intent-file and saved-asset links never throw. A failure becomes a placeholder attachment and the text around it still renders. A failed remote load falls through to the fallback loader.
   4. Saved-asset PDFs and text are not supported in this route; they show the placeholder.
   5. Only loaded images open the image lightbox (`lightboxImage(for:)`). Videos and retry placeholders have their own tap actions. A retry clears the failure in the same session loader that fetched (`prepareRetry(using:)`), then recreates the attributed string (`attachmentAttempt`), because Textual resolves URLs once per string. Successful media still comes from the cache.
7. **Textual attachment sizing.** Textual draws an attachment's ideal-sized symbol into a square run, so PDF and video cards use a square frame and the image thumbnail matches the measured image proportions. `sizeThatFits` builds traits with typed setters, because Textual measures off the main actor.
8. **Lightbox lifetime.** The PDF and video lightboxes keep their own file, apart from the transcript attachment and cache. Dismissal can cancel the video task while audio session activation blocks; the view then creates no player and does not leak the activation.
9. **Text file viewer.** `WorkspaceTextFileView` uses TextKit 2, which lays out only the visible viewport. It keeps native selection and scrolling and never touches the legacy `layoutManager`, because that switches the view to TextKit 1. `LineNumberTextView` uses a fixed line height, because TextKit 2 spaces empty paragraphs unevenly with `lineSpacing`. After the viewport lays out, it corrects the scroll position to the measured baseline, because TextKit 2 moves estimated fragments. The gutter measures from the line start, because the horizontal viewport can leave out short lines.

## Consequences

- New media kinds must go through the session loader and handle cancellation without a failure state.

## Code

- `ContentBlockView`, `ContentBlockBody`: `==`, `imageNeedsHydration`, `lightboxPendingHydration`
- `AttachmentReferenceImageView`: `loadedKey`; `AttachmentReferenceVideoView`; `ImageAttachmentThumbnail`
- `ChatImageSaver`, `ChatImageSaveOutcome`, `ImageSaveAlertModel`, `ImageActionMenuItems`, `ImageLightboxView`
- `MarkdownImageRoute`: `route(for:)`; `IntentFileAttachmentLoader`: `resolvedAttachment(for:text:fallback:)`, `assetMedia`
- `IntentFileImageAttachment`, `IntentFileFailureAttachment`, `IntentFileVideoAttachment`: `prepareRetry(using:)`, `IntentFilePDFAttachment`
- `MarkdownTextView`: `assetMediaFetcher(session:)`, `lightboxImage(for:)`, `attachmentAttempt`
- `PDFLightboxView`, `VideoLightboxView`, `WorkspaceTextFileView`, `LineNumberTextView`
