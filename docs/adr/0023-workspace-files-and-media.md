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

## Code

- `RemoteImageLoader`: `image(for:)`, `forgetFailure(for:)`, `shouldNegativelyCache`, `streamCappedBytes`, `failedKeys`
- `FileSyntaxHighlighter`: `highlight(source:path:dark:)`
