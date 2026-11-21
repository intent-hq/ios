# 0012. Attachment placement and resolution

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Chat attachments are stored in a workspace's attachment registry on the daemon (PROTOCOL §5.5, §5.9). The app places payloads up to 1 GiB and shows attachment images and videos in the transcript.

## Decision

1. **Placement follows cloudlands-fe.** `AttachmentUploadService` uses the single-shot `file.placeAttachment` `data` arm up to 25 MB. Above that it uses the staged session `file.attachmentUpload.begin` → sequential `chunk`s → `commit`.
2. **Limits.**
   1. `maxSingleShotBytes` is 25 MiB: base64 inflates about 4/3 and a JSON-RPC frame is capped at 40 MiB (PROTOCOL §1.3). It matches FE `MAX_REMOTE_ATTACHMENT_BYTES`.
   2. `maxAttachmentBytes` is the daemon's 1 GiB cap. The app checks it before any RPC.
   3. `uploadChunkBytes` is the daemon's 16 MiB decoded-slice cap. The effective chunk is the smaller of this and `begin`'s `maxChunkBytes`.
   4. `transferTimeout` is 5 minutes per call. A 16 MiB chunk is about 21 MiB of base64, and `commit` reassembles and SHA-256-verifies up to 1 GiB before it replies. It matches FE `UPLOAD_TRANSFER_TIMEOUT_MS`.
3. **Memory and isolation.**
   1. File payloads stream off disk through `FileHandle`. A 1 GiB attachment is never in memory at once. Photos videos always use `placeFile(…)`.
   2. Hashing and disk reads are nonisolated and stay off the main actor. Only the RPCs hop, like `WorkspaceFileImageLoader`.
   3. `read(upToCount:)` can return fewer bytes than asked before EOF. The reader accumulates a full chunk, so a short read cannot stage fewer bytes than declared and fail the commit size check.
4. **Failure.** Any failure after `begin` aborts the session and rethrows. Abort is best-effort: it is idempotent and the daemon sweeps orphaned sessions on the next `begin`.
5. **Result shape.** `commit` returns the same shape as `file.placeAttachment`. `mimeType` and `uploadedAt` are additive (v6.12) and presence-detected.
6. **Resolution.** `AttachmentImageLoader` resolves an attachment id to its workspace path with `file.getAttachmentInfo` (§5.9), then reads bytes through `WorkspaceFileImageLoader` (`file.readChunk`). This matches FE `attachment-image-url.ts`.
   1. Attachment rows are immutable, so resolved paths are cached for the session. Failures are not cached; a transient daemon error can succeed on the next render.
   2. The path cache is deliberately uncapped (ios#264). It grows only with attachments the transcript rendered, at about 280 B per entry (`SessionCacheBoundsMeasurementTests`). Eviction would only repeat an immutable lookup.
   3. A registry row survives a file delete. `exists: false` maps to `LoadError.fileMissing`.
   4. The resolve task writes the cache itself, so a cancelled awaiter (a row scrolled away) does not lose a finished resolution.
   5. A user retry clears the byte-fetch negative cache for the resolved path, so the fetch runs again.

## Consequences

- Large uploads hold one chunk in memory at a time.
- Orphaned upload sessions can exist on the daemon until the next `begin`.

## Code

- `AttachmentUploadService`: `maxSingleShotBytes`, `maxAttachmentBytes`, `uploadChunkBytes`, `transferTimeout`, `placeData(…)`, `placeFile(…)`, `placeChunked(…)`, `placeFromFile(…)`, `PlacedAttachment`
- `AttachmentImageLoader`: `pathCache`, `resolvePath(workspaceId:attachmentId:)`, `retryImage(workspaceId:attachmentId:)`, `LoadError.fileMissing`
