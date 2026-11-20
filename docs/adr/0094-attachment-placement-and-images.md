# 0094. Attachment placement and image loading

**Status:** Accepted (recorded 2026-11-20 from test comments)

## Context

The composer places files in the workspace through the daemon (PROTOCOL §5.9). Transcript rows refer to attachments by id, and the app resolves them to bytes.

## Decision

1. **Placement.**
   1. Small payloads use one `file.placeAttachment` call. Larger payloads use a chunked `file.attachmentUpload.*` session with chunks of at most 16 MiB.
   2. The client computes SHA-256 in streaming blocks and rejects files over 1 GiB before any RPC.
   3. When a chunk fails, the client aborts the session on a best-effort basis. A failed abort does not hide the original error.
2. **Image references.**
   1. The loader resolves `file.getAttachmentInfo` to a workspace-relative path, then reads bytes with `file.readChunk`. Paths are cached.
   2. As in the desktop (`attachment-image-url.ts`), a transient resolution error is not cached; the next render pass retries.
   3. A failed byte fetch is cached negatively for the session. `retryImage` clears that entry, so a retry really fetches again.
   4. A second load for the same attachment joins the read in flight.

## Code

- `AttachmentUploadService`: `hashBlockBytes`
- `AttachmentImageLoader`: `image(workspaceId:attachmentId:)`, `retryImage`
- `AttachmentUploadServiceTests`, `AttachmentImageLoaderTests`
