# ADR-0064: Composer attachment pipeline: imports, limits, and send-time encoding

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConversationAttachmentPipeline` (`Intent/Services/ConversationAttachmentPipeline.swift`), `ConversationAttachmentPipeline` photo extension and `PhotoLibraryVideos` (`Intent/Services/ConversationAttachmentPipeline+Photos.swift`), `ImportedPhotoVideo` (`Intent/Services/ImportedPhotoVideo.swift`)
- Related issues: #463, #619, #861

## Context

`ConversationAttachmentPipeline` is main-actor-owned composer attachment state
and send-time placement logic. It imports photos, videos, pasted images, and
files, checks limits, encodes images, and places attachments before a send.

## Decisions

### 1. Security-scoped access lives as long as the file is in the composer

Applies to: `ConversationAttachmentPipeline.addFiles(_:)`, `removePendingFile(at:)`, `clearPendingFiles()`, `deinit`

Security-scoped access begins when a file is added. It stays held until the
file is removed, until a clear after a successful send or queue, or until
deinitialization.

### 2. A send takes extra access leases for its captured files

Applies to: `ConversationAttachmentPipeline.retainFileAccess(for:)`, `clearPendingFiles(ids:)`

The captured selection must stay readable even when it is removed from the
composer while another attachment uploads. `retainFileAccess` takes extra
leases, balanced independently of the composer's own security-scoped access.
`clearPendingFiles(ids:)` consumes only this send's selection, not files added
while the send awaited RPCs.

### 3. Image byte limits

Applies to: `maxImageReferenceBytes`, `maxOutgoingImageBytes`, `maxOutgoingImagesBytes`

- `maxImageReferenceBytes` (30 MiB) is a named aggregate limit that mirrors the
  daemon-facing image contract.
- `maxOutgoingImageBytes` (1 MiB per image) and the aggregate are conservative
  client budgets. They leave room for base64 and provider context. They are not
  a guarantee against any provider's total request limit.
- `maxOutgoingImagesBytes` scales with
  `Constants.Conversation.Composer.maximumImageSelectionCount`, so every
  allowed image keeps its 1 MiB share.
- `no_magic_numbers` is disabled around these constants to keep the MiB
  conversions and the ordered JPEG quality ladder together as named encoding
  policy.

### 4. Encoding runs off the main actor and never mutates the original image

Applies to: `encodeOffMainActor(_:using:)`, `outgoingJPEGData(for:)`, `buildImageBlocks(from:workspaceId:)`

The encoding extension is nonisolated so it never runs on the main actor.
Resizing and JPEG encoding can take hundreds of milliseconds per large photo,
so it runs on the concurrent pool. `outgoingJPEGData` bakes orientation into
bounded pixel dimensions before JPEG encoding. It never modifies the original
image retained by the draft or send attempt. When every pass stays over
budget, it returns the last data, and the caller rejects it before any RPC.
A cancelled send stops before encoding the next photo.

### 5. The Assistant sends images inline

Applies to: `buildImageBlocks(from:workspaceId:)`

The Assistant (`Workspace.chiefWorkspaceId`) has no filesystem root for
attachment placement (#619). Inline image blocks are a supported protocol arm,
not an error fallback.

### 6. Paste snapshots every item at once and commits atomically

Applies to: `pasteImages()`

Only the native Paste action calls `pasteImages`. It snapshots each image item
before returning to the run loop, while lazy clipboard providers are still
available. The batch is committed atomically; an unreadable item is never
dropped silently.

### 7. Photo import consumes each batch before suspending

Applies to: `startLoadingSelectedPhotos(workspaceId:)`, `loadSelectedPhotos(workspaceId:)`, `loadPhotoImage(_:)`

- Each batch is consumed before suspending. Otherwise picker changes can load a
  selection twice, or erase another selection made during import.
- After an import ends, `startLoadingSelectedPhotos` runs again. A new visible
  composer can select a batch while cancellation of the previous import is
  unwinding, and that selection must not be discarded.
- A new pick clears `attachmentImportError`, because the question tray shows it
  inline with no dismissal to clear it.
- Videos never use image slots. A batch with too many images keeps its videos
  but rejects all of its images, with the limit alert.
- `loadPhotoImage` returns false only for a transfer or decode failure worth
  reporting; cancellation stays silent. Capacity is checked again after the
  load, because paste or another selection can consume capacity while Photos
  loads the transferable data.

### 8. Library videos import as files and are re-measured before upload

Applies to: `PhotoLibraryVideos`, `validateVideos(in:workspaceId:)`

Picked library videos import as files, not images. Files can grow after
selection, so `validateVideos` reads disk metadata again before any upload
instead of relying only on the picked size.

### 9. One shared owner for an imported video file

Applies to: `ImportedPhotoVideo` (`Intent/Services/ImportedPhotoVideo.swift`)

`ImportedPhotoVideo` owns a disk-backed Photos export. Composer selections and
send attempts share this owner, so removing a preview cannot delete a file that
is still uploading. `importFile(at:)` copies the file before the Photos transfer
callback returns, because the source URL is valid only inside that callback.
Neither the copy nor poster creation reads the whole movie into `Data`, and
both run off the UI actor. `maxBytes` keeps the shared 200 MiB composer and
transcript cap explicit; all other files keep the 1 GiB cap.

### 10. Import failures alert; cancellation stays silent

Applies to: `attachmentImportError`, `reportFileImportFailure(_:)`, `View.attachmentImportAlert(_:)`

`attachmentImportError` holds picked photos or files that could not be added
(#463). Successful picks stay attached. A user cancellation in the file
importer stays silent.

### 11. Placement failures restore the draft

Applies to: `surfaceImagePlacementFailure(_:content:imageRecovery:messageText:)`

A connection drop restores the draft silently, because
`DiagnosticErrorOwnership.alertMessage` returns nil for it; read-only mode
explains it.

### 12. One image limit on every surface

Applies to: `Constants.Conversation.Composer.maximumImageSelectionCount`

The image limit is 10 on every surface: the composer, the question tray, and
workspace creation. This is closer to the desktop, which has no count cap.
Every surface derives its capacity and its limit copy from
`maximumImageSelectionCount` (#861). The Assistant accepts no videos, so its
picker is images-only and Photos is disabled once its image slots are full.

### 13. Test seams

Applies to: `loadPhotoData`, `photoVideos`, `encodeOutgoingJPEG`

`loadPhotoData` lets tests hold an import in flight; production reads the
item's transferable data. `photoVideos` lets tests pick library videos.
`encodeOutgoingJPEG` lets tests observe where encoding runs; production always
uses the bounded resize and JPEG ladder.
