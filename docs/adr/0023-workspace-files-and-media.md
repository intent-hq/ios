# 0023. Workspace files and media

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

The app reads workspace files, images, PDFs and videos from the daemon and renders them. Decoding can be slow, and files can be large.

## Decision

1. **Off the main thread.** `FileSyntaxHighlighter` decodes a large file's highlight runs in a detached task; it takes tens of milliseconds.
2. **Remote images.** `RemoteImageLoader` fetches remote http(s) markdown images with URLSession and decodes them through the workspace-image downsampling path, with the same `maxFileBytes`.
   1. Results are cached per URL so scrolling never refetches. Concurrent requests share one fetch. The task writes the cache, so a cancelled awaiter does not lose a finished fetch. The `NSCache` key is `NSString`, the reference type it requires.
   2. Content and HTTP failures are cached negatively for the session; cancellation and offline URLErrors are not, so reconnecting recovers. `forgetFailure(for:)` allows an explicit retry. The negative cache is deliberately uncapped (ios#264): about 140 B per URL (`SessionCacheBoundsMeasurementTests`).
   3. Download and decode run `@concurrent`, off the UI thread. The default fetcher streams the body and aborts past `maxFileBytes`, so a hostile or endless server cannot buffer unbounded data.
3. **Workspace file media (`WorkspaceFileImageLoader`).**
   1. Media is fetched with chunked `file.readChunk` reads and base64-decoded into an image, a video poster or a local file. Results are cached per (workspace, path); concurrent requests share one fetch; the task writes the cache so a cancelled awaiter does not lose it. Assets (`note.readAsset`, one base64 reply) are content-addressed, so a replaced image is a new key, and keys never collide with paths.
   2. `chunkLength` is 4 MiB, well under the daemon's 16 MiB decoded cap. `pdfChunkLength` is 256 KiB: about 350 KB of base64 takes about 2.8 s at 1 Mbit/s, under the 10 s RPC timeout on Tailcat links.
   3. `maxFileBytes` (32 MiB) bounds assembly. Images decode through the ImageIO downsampling thumbnail path capped at `maxPixelSize` (2048), so a small file that declares huge dimensions cannot balloon memory (`decodeImage(_:)`, shared with `RemoteImageLoader`).
   4. `cacheTotalCostLimit` (64 MiB) is a decoded-memory budget; videos and PDFs charge only their preview. `cacheFileCountLimit` bounds cache-owned temp files to eight per session. `cachedFileKeys` holds FIFO keys only, never extra file owners; a refetch after eviction replaces its slot.
   5. Permanent and daemon failures are cached negatively for the session; cancellation and offline errors are not. The negative cache is uncapped (ios#264): about 160 B per key.
   6. Assembly, base64 and decode run `@concurrent`; only each RPC hops to the main actor. Videos and PDFs stream to disk with one decoded chunk in memory.
   7. PDF failure diagnostics record closed categories only, once per fetch, never a workspace, filename, URL or foreign error text.
4. **PDFs (`WorkspacePDF`).** Metadata and thumbnail are immutable; PDFKit documents stay in the decoding task or viewer, and shared ownership keeps the file alive. `shareURL` hard-links or copies the cache file under the original name (ios#803), so share and Save to Files never expose the cache name; `exportFileName(for:)` makes a safe single-component `.pdf` name. Thumbnail and viewer use the same bounded validation and empty-password unlock; encryption alone is not a reason to reject. The signature check uses a range search, because `Data.contains` tests one byte. `prepare` takes ownership of the temp download, including on failure.
5. **Videos and text files.** `WorkspaceVideo` and `WorkspaceTextFile` are immutable with shared ownership, so the temp file survives cache eviction, full-screen playback and Share. No player is created until the user taps the poster. Posters use a fixed 3× scale. Cleanup on last release runs detached at utility priority, never on the UI executor and never retaining the owner. `.ts`/`.mts`-style extensions are TypeScript sources unless the server reports video (#883). Download and strict text decoding stay off the UI executor, and the text file keeps its original name in a unique directory for Share.
6. **File tree (`WorkspaceFilesStore`).** Only loaded, expanded branches are flattened; root children have depth zero. Re-entering the same workspace keeps expansion and listings. `refresh()` reloads the root and visible expanded folders and keeps rows on failure. `reset()` invalidates pending replies synchronously, including for a reused workspace id.

## Code

- `WorkspaceFileImageLoader`: `image(workspaceId:path:)`, `assetImage(workspaceId:assetId:)`, `requestAsset(workspaceId:assetId:)`, `chunkLength`, `pdfChunkLength`, `maxFileBytes`, `maxPixelSize`, `cacheTotalCostLimit`, `cachedFileKeys`, `failedKeys`, `decodeImage(_:)`, `fetchAndDecode`, `recordPDFFailure(_:store:)`
- `WorkspaceVideo`: `prepare`, `isVideo`; `WorkspaceTextFile`: `load`; `WorkspaceFileMediaBox`
- `WorkspacePDF`: `shareURL`, `exportFileName(for:)`, `openDocument(at:)`, `prepare(fileURL:name:byteCount:)`; `WorkspaceFilesStore`: `rows`, `start(workspaceId:)`, `refresh()`, `reset()`
- `RemoteImageLoader`: `image(for:)`, `forgetFailure(for:)`, `shouldNegativelyCache`, `streamCappedBytes`, `failedKeys`
- `FileSyntaxHighlighter`: `highlight(source:path:dark:)`
