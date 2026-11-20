# ADR-0405: Attachment placement and loading follow the daemon registry contract

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `AttachmentUploadService` (`Intent/Services/AttachmentUploadService.swift`),
  `AttachmentImageLoader` (`Intent/Services/AttachmentImageLoader.swift`)
- Related issues: ios#264

## Context

Chat attachments live in a workspace's attachment registry on the daemon.
`AttachmentUploadService` places payloads there. `AttachmentImageLoader` loads
attachment-reference images and videos back for the transcript.

## Decisions

### 1. Placement uses a single-shot arm up to 25 MB and a chunked session above it

Applies to: `AttachmentUploadService`, `AttachmentUploadService.place(...)`,
`AttachmentUploadService.placeFromFile(...)`

Placement uses `file.placeAttachment` and `file.attachmentUpload.*` (PROTOCOL
§5.9). It matches cloudlands-fe's attachment placement. The single-shot `data`
arm is used up to 25 MB. Above that, a staged chunked session runs: `begin`,
sequential `chunk`s, `commit`, up to the daemon's 1 GiB cap. File payloads
stream off disk through `FileHandle`, so a 1 GiB attachment is never in memory
at once. `placeFile` with `forceChunked` is used by Photos videos at every size.

### 2. Limits

Applies to: `AttachmentUploadService.maxSingleShotBytes`, `.maxAttachmentBytes`,
`.uploadChunkBytes`, `.transferTimeout`, `UploadError.payloadTooLarge`

1. `maxSingleShotBytes` (25 MiB): base64 inflates by about 4/3, and the
   serialized JSON-RPC frame is capped at 40 MiB (PROTOCOL §1.3). It matches
   cloudlands-fe's `MAX_REMOTE_ATTACHMENT_BYTES`.
2. `maxAttachmentBytes` (1 GiB): `file.attachmentUpload.begin` rejects declared
   sizes above 1 GiB (PROTOCOL §5.9). The client checks it before any RPC and
   throws `payloadTooLarge`.
3. `uploadChunkBytes` (16 MiB) is the daemon's decoded-slice cap. The effective
   chunk size is the minimum of this and `begin`'s `maxChunkBytes`.
4. `transferTimeout` (5 minutes) applies per call to placement, chunk sends and
   commit. A 16 MiB chunk is about 21 MiB of base64 on the wire, and commit
   reassembles and SHA-256-verifies up to 1 GiB before it replies. It matches
   cloudlands-fe's `UPLOAD_TRANSFER_TIMEOUT_MS`.

### 3. Placement result shape

Applies to: `AttachmentUploadService.PlacedAttachment`

`PlacedAttachment` is the `file.placeAttachment` result.
`file.attachmentUpload.commit` returns the same shape. `path` is
workspace-relative under `.intent/attachments/`. The registry fields `mimeType`
and `uploadedAt` are additive (v6.12) and presence-detected.

### 4. Chunked session flow and abort

Applies to: `AttachmentUploadService.placeChunked(_:readChunk:onProgress:)`,
`AttachmentUploadService.RPCClient.abort(uploadId:)`

`begin` declares the size and SHA-256. Chunks are sent in order and bounded by
the daemon-returned `maxChunkBytes`. Then `commit` runs. Any failure after
`begin` aborts the session and rethrows. The abort is best-effort and its error
is ignored: abort is idempotent, and the daemon sweeps orphaned sessions on the
next `begin`. Progress is the fraction of chunks the daemon acknowledged; only
the chunked path reports it.

### 5. File chunks are read until full or EOF

Applies to: `AttachmentUploadService.placeFromFile(...)`

`FileHandle.read(upToCount:)` may return fewer bytes than requested before EOF.
The reader accumulates until the chunk is full or EOF, so a short read cannot
stage fewer bytes than declared and fail the commit's size check.

### 6. Hashing and disk reads stay off the main actor

Applies to: `AttachmentUploadService` placement functions

Placement functions are `nonisolated` and `@concurrent`. Only the RPCs hop to
the main actor. This is the same pattern as `WorkspaceFileImageLoader`.

### 7. Attachment loading resolves the path, then reads the bytes

Applies to: `AttachmentImageLoader`

Attachment-reference images and videos (PROTOCOL §5.5) resolve the registry row
to its workspace-relative path with `file.getAttachmentInfo` (§5.9). The bytes
are fetched and decoded through `WorkspaceFileImageLoader` (`file.readChunk`).
This matches the frontend's `attachment-image-url.ts`.

### 8. Resolved paths cache for the session; failures do not

Applies to: `AttachmentImageLoader.pathCache`, `AttachmentImageLoader.resolvePath(...)`

Attachment rows are immutable: an id never changes its path. Resolved paths
therefore cache for the session, keyed by workspace id and attachment id.
Resolution failures are not cached, because a transient daemon error may
succeed on the next render pass. The path is stored inside the resolution task,
so an awaiter cancelled early (the view scrolled away) does not lose a
completed resolution.

The cache is deliberately uncapped (ios#264). It grows only with distinct
attachments that the transcript rendered, at about 280 B per entry as measured
by `SessionCacheBoundsMeasurementTests`. A 10k-attachment session keeps about
2.6 MiB. Eviction would only re-run an immutable `file.getAttachmentInfo`
resolution.

### 9. A missing file is a distinct error

Applies to: `AttachmentImageLoader.LoadError.fileMissing`

The registry row can survive a delete of its file (`exists: false`, PROTOCOL
§5.9). That case throws `fileMissing`.

### 10. Retry clears the byte-fetch negative cache

Applies to: `AttachmentImageLoader.retryImage(...)`, `AttachmentImageLoader.retryVideo(...)`

A user retry clears the byte-fetch negative cache for the resolved path, when
known, so the fetch really runs again. Path resolution failures were never
cached, so they retry on their own.
