# ADR-0708: Workspace file media loads in bounded chunks and is cached per session

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspaceFileImageLoader` (`Intent/Services/WorkspaceFileImageLoader.swift`,
  `Intent/Services/WorkspaceFileImageLoader+Documents.swift`),
  `WorkspacePDF` (`Intent/Services/WorkspacePDF.swift`),
  `WorkspaceVideo`, `WorkspaceFileMediaBox` (`Intent/Services/WorkspaceVideo.swift`),
  `WorkspaceTextFile` (`Intent/Services/WorkspaceTextFile.swift`)
- Related issues: ios#264, ios#803, #883

## Context

Transcripts show images, videos, PDFs, and text files from the workspace. The
app fetches them with chunked `file.readChunk` reads over the paired WebSocket,
or with one `note.readAsset` read for assets. Memory, disk, and RPC time must
stay bounded, and scrolling must not refetch.

## Decisions

### 1. Chunked fetches, cached per file, single-flight

Applies to: `WorkspaceFileImageLoader`, `WorkspaceFileImageLoader.cachedMedia`

The loader assembles and base64-decodes `file.readChunk` slices into an image,
or a video poster and local file. Results are cached per (workspaceId, path), so
transcript scrolling never refetches, and concurrent requests for the same file
share one in-flight fetch.

The fetch task stores its result in the cache itself, so an awaiter that is
cancelled early (the view scrolled away) does not lose the completed fetch.

### 2. Asset images use their own key namespace

Applies to: `WorkspaceFileImageLoader.assetImage`, `ChunkRequester.requestAsset`,
`WorkspaceFileImageLoader.forgetAssetFailure`

Asset IDs come from the `note.saveAsset` / `workspace-asset://` namespace, for
example the workspace `statusImageAssetId`. They are content-addressed, so a
replaced image is a new key and refetches, and keys never collide with file
paths. `note.readAsset` is one read: the daemon answers the whole asset as
base64 (`{ assetId, mimeType, data, sizeKb }`). `forgetAssetFailure` is the
retry path for status image taps.

### 3. Size and memory limits

Applies to: `WorkspaceFileImageLoader.chunkLength`, `pdfChunkLength`, `maxFileBytes`, `maxPixelSize`,
`cacheTotalCostLimit`, `cacheFileCountLimit`

1. `chunkLength` (4 MiB) is well under the daemon's 16 MiB decoded cap. Most
   images resolve in one round trip.
2. `pdfChunkLength` (256 KiB): about 350 KB of base64 takes about 2.8 s at
   1 Mbit/s, which leaves headroom under the 10-second RPC timeout on remote
   Tailcat links. Other media keep `chunkLength`.
3. `maxFileBytes` (32 MiB): the loader refuses to assemble larger files.
   Transcript images should be far smaller, and the cap bounds memory on a
   pathological path.
4. `maxPixelSize` (2048) is the longest decoded edge. Decoding goes through
   ImageIO's downsampling thumbnail path, so a small compressed file that
   declares enormous pixel dimensions cannot balloon decode or render memory.
5. `cacheTotalCostLimit` (64 MiB) is the decoded-memory budget. A 2048×2048 BGRA
   image is about 16 MB. Videos and PDFs charge only their preview; their
   temporary files have a separate count bound.
6. `cacheFileCountLimit` (8): eight downloads bound the cache-owned temporary
   files per backend session. Attachments and viewers may retain evicted files
   until they release them.

### 4. Cache keys and the temporary-file FIFO

Applies to: `WorkspaceFileImageLoader.cache`, `WorkspaceFileImageLoader.cachedFileKeys`,
`WorkspaceFileImageLoader.store`, `WorkspaceFileMediaBox`

`NSCache` requires a reference-type key, and `NSString` preserves that
Foundation contract; this is why the `legacy_objc_type` rule is disabled at
each use. `NSCache`'s value must also be a reference type, so media is wrapped
in `WorkspaceFileMediaBox`.

`cachedFileKeys` holds FIFO keys only, never extra file owners. `NSCache` may
evict earlier, which makes the count conservative; stale keys cannot increase
the disk bound. A refetch after a memory-pressure eviction replaces its old
FIFO slot.

### 5. Session negative cache

Applies to: `WorkspaceFileImageLoader.failedKeys`, `WorkspaceFileImageLoader.shouldNegativelyCache`,
`WorkspaceFileImageLoader.forgetFailure`

`failedKeys` holds keys whose fetch or decode failed, for the session, so a
persistently broken link does not refetch on every scroll into view. Permanent
and daemon failures are remembered. Cancellation and transient connection-drop
or offline errors (for example read-only reconnecting mode) are not.

`failedKeys` is intentionally uncapped (ios#264). It grows only with distinct
failed links that the transcript rendered, at about 160 B per entry as measured
by `SessionCacheBoundsMeasurementTests`. A 10k-link session retains about
1.5 MiB, which is noise next to one `cacheTotalCostLimit`.

`forgetFailure` drops a key so a user retry (for example tapping a failed
attachment placeholder) refetches.

### 6. Decoding runs off the main actor

Applies to: `WorkspaceFileImageLoader.fetchAndDecode`, `fetchAndDecodeAsset`, `fetchBytes`,
`writeFileBytes`, `decodeImage`, `decodedCost(of:)`, `fetchVideo`

These functions are `@concurrent`, so chunk assembly, base64 decoding, and image
decoding run on the global executor. Only each RPC hops to the main actor. This
keeps large decodes off the UI thread.

`fetchBytes` stops at an EOF window (`bytesRead == 0`) or when the whole file is
assembled. Videos and PDFs share the bounded, validated chunk-to-disk path in
`writeFileBytes`. `fetchVideo` streams videos to disk, so only one decoded chunk
is held in memory. Image and saved-asset assembly keep their smaller cap.

`decodeImage` and `decodedCost(of:)` (the approximate decoded byte size used as
the `NSCache` cost) are shared with `RemoteImageLoader`.

### 7. PDF failure diagnostics are privacy-safe

Applies to: `WorkspaceFileImageLoader.recordPDFFailure`

The record uses closed categories only. It never persists a workspace,
filename, URL, or foreign error description. There is one record per fetch, not
one per cached failure.

### 8. Media objects own their temporary files

Applies to: `WorkspacePDF`, `WorkspaceVideo`, `WorkspaceTextFile`, `WorkspacePDF.prepare`, `WorkspaceVideo.prepare`

Each type is immutable with shared ownership, which keeps the downloaded file
alive through cache eviction, full-screen playback, and Share. PDFKit documents
stay confined to the decoding task or the viewer. No video player is created
until the user taps the poster.

`prepare` takes ownership of a completed temporary download, including on
failure. A video file is removed on failure or when the last cache, thumbnail,
or player owner releases it. `WorkspaceVideo.deinit` may run on the main actor,
so the cleanup is a detached utility task that neither inherits the UI executor
nor retains the deinitializing owner.

`WorkspaceTextFile.load` keeps download and strict decoding off the UI executor.
It stores the file under its original name in an owned, unique directory, so the
share sheet exports the original name.

### 9. PDFs are shared under their original name

Applies to: `WorkspacePDF.shareURL`, `exportFileName(for:)`, `shareDirectory(for:)`, `makeShareURL`

`shareURL` holds the cached bytes under the original document name (ios#803), so
the share sheet and Save to Files never expose the `chat-pdf-<UUID>` cache name.
It falls back to `url` when the named copy could not be created.

`makeShareURL` hard-links (or copies) the cache file under its export name. The
cache file keeps its unique name for isolation and cleanup. The share directory
is a sibling of the cache file and is removed together with it.
`exportFileName` returns a single-component, non-hidden filename that ends in
`.pdf`; path separators, colons, and control characters become hyphens.

### 10. PDF validation

Applies to: `WorkspacePDF.openDocument(at:)`

The thumbnail step and the viewer use the same bounded validation and the same
empty-password unlock. Encryption alone is not a reason to reject a PDF; only a
document that is still locked needs a password. The signature check uses
`range(of:)`, because `Data.contains` tests one byte, not the full signature
sequence; this is why `contains_over_range_nil_comparison` is disabled there.

### 11. Video detection and posters

Applies to: `WorkspaceVideo.isVideo(path:mimeType:)`, `WorkspaceVideo.posterScale`

UTType maps `ts` and `mts` to MPEG transport streams. In a workspace they are
TypeScript sources unless the server explicitly reports a video MIME type
(#883).

`posterScale` is a fixed 3× cap. It covers high-density transcript thumbnails
without a screen lookup.
