# 0019. Composer attachment pipeline

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

The conversation composer collects photos, pasted images, library videos and files, then places them at send time. Picks, pastes and sends can overlap. Large photos are slow to encode.

## Decision

1. **Ownership.** `ConversationAttachmentPipeline` owns composer attachment state on the main actor. Security-scoped access starts when a file is added and is held until removal, a clear after a successful send or queue, or deinit.
2. **Photos import.**
   1. Library videos import as files (`PhotoLibraryVideos`) and never use image slots. A batch with too many images keeps its videos and rejects all its images with the limit alert.
   2. Each batch is consumed before any suspension, so picker changes cannot load a selection twice or erase a selection made during import. A new composer can start a batch while the previous import's cancellation unwinds; that selection is kept.
   3. A new pick clears the earlier import warning. Capacity is checked again after Photos loads data, because paste or another pick can use slots meanwhile.
   4. Cancellation is silent. Only transfer or decode failures are reported. Failed picks are reported while successful picks stay attached (#463).
   5. The image limit is 10 on every surface (composer, question tray, workspace creation), closer to the desktop, which has no count cap. Every surface derives its capacity and copy from `Constants.Conversation.Composer.maximumImageSelectionCount` (#861). The Assistant accepts no videos, so its picker is images-only and Photos is disabled once the image slots are full (added from `ComposerPhotoLimitTests` comments).
3. **Paste.** `pasteImages()` runs only from the native Paste action. It snapshots each item before returning to the run loop, while lazy clipboard providers are still available. A batch is committed at once; an unreadable item is never dropped silently.
4. **Files.** Files can grow after selection. Disk metadata is checked again before upload. `retainFileAccess(for:)` takes extra leases for the send's selection, balanced separately from the composer's own access, so removal during another upload cannot break a send. `clearPendingFiles(ids:)` clears only this send's selection, not files added while RPCs ran.
5. **Image budgets.**
   1. `maxImageReferenceBytes` (30 MiB) mirrors the daemon-facing image contract.
   2. `maxOutgoingImageBytes` (1 MiB) is a conservative client budget that leaves room for base64 and provider context. It does not guarantee any provider's total limit. `maxOutgoingImagesBytes` scales it by the selection limit.
   3. `outgoingJPEGData(for:)` bakes orientation into bounded pixel sizes before JPEG encoding and never modifies the draft's original image. The caller rejects data still over budget before any RPC.
   4. Encoding is `@concurrent`, off the main actor; it can take hundreds of milliseconds per large photo. A cancelled send stops before the next photo.
6. **Assistant.** The Assistant workspace has no filesystem root for placement (#619). It sends inline image blocks, which are a supported protocol arm, not an error fallback.
7. **Placement failure.** A dropped send restores the draft silently; read-only mode explains the failure.

## Code

- `ConversationAttachmentPipeline`: `pasteImages()`, `retainFileAccess(for:)`, `clearPendingFiles(ids:)`, `maxImageReferenceBytes`, `maxOutgoingImageBytes`, `maxOutgoingImagesBytes`, `outgoingJPEGData(for:)`, `encodeOffMainActor(…)`, `buildImageBlocks(from:workspaceId:)`, `attachmentImportError`
- `ConversationAttachmentPipeline` (Photos): `startLoadingSelectedPhotos`, `loadSelectedPhotos`, `loadPhotoImage(_:)`, `reportFileImportFailure(_:)`, `attachmentImportAlert(_:)`
- `PhotoLibraryVideos`
