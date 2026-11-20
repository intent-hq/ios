# ADR-0616: RemoteImageLoader caches remote markdown images per URL

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `RemoteImageLoader` (`Intent/Services/RemoteImageLoader.swift`)
- Related issues: ios#264

## Context

`RemoteImageLoader` fetches remote http(s) markdown images over URLSession and
decodes them through the same downsampling path as workspace-file images
(`WorkspaceFileImageLoader`).

## Decisions

### 1. Cache, share, and negatively cache per URL

Applies to: `RemoteImageLoader.image(for:)`

Results are cached per URL, so transcript scrolling never refetches.
Concurrent requests for the same URL share one in-flight fetch. Failed URLs are
negatively cached for the session.

### 2. The image is cached inside the fetch task

Applies to: `RemoteImageLoader.image(for:)`

The task stores the image in the cache itself, so an awaiter that is cancelled
early (the view scrolled away) does not lose the completed fetch.

### 3. Which failures are remembered

Applies to: `RemoteImageLoader.failedKeys`, `RemoteImageLoader.shouldNegativelyCache(_:)`,
`RemoteImageLoader.forgetFailure(for:)`

1. Content and HTTP failures are remembered for the session, so a persistently
   broken image does not refetch on every scroll into view.
2. Cancellation and transient offline or connectivity `URLError`s are not
   remembered, so reconnecting recovers naturally.
3. `failedKeys` is intentionally uncapped (ios#264). It grows only with
   distinct failed URLs that the transcript actually rendered, at about 140 B
   per entry as measured by `SessionCacheBoundsMeasurementTests`. Even a
   10k-URL session keeps about 1.3 MiB, which is noise next to the
   decoded-image cost limit.
4. `forgetFailure(for:)` clears a failed URL so an explicit retry can refetch
   it.

### 4. Size limits

Applies to: `RemoteImageLoader.maxFileBytes`, `RemoteImageLoader.streamCappedBytes(from:)`

1. Responses past `maxFileBytes` are not decoded. The bound is the same as for
   workspace-file images.
2. The default fetcher streams the response body and aborts as soon as it
   exceeds `maxFileBytes`, so a hostile or endlessly streaming server cannot
   buffer unbounded data before the size guard runs. `DataFetcher` is
   injectable for tests.

### 5. Download and decode run off the UI thread

Applies to: `RemoteImageLoader.fetchAndDecode(fetchData:url:)`

`fetchAndDecode` is explicitly `@concurrent`, so the download and the image
decode run on the global executor and large decodes stay off the UI thread.

### 6. NSCache uses NSString keys

Applies to: `RemoteImageLoader.cache`

`NSCache` requires a reference-type key. `NSString` keeps that Foundation
contract, which is why the `legacy_objc_type` lint rule is disabled on those
lines.
