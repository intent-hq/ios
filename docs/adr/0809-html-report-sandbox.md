# ADR-0809: HTML reports render as inert, isolated documents with a bounded resource budget

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `HTMLFileResourcePolicy`, `HTMLFileResourceHandler` (`Intent/Views/Conversation/Content/HTMLFileResources.swift`), `HTMLFileWebView` (`Intent/Views/Conversation/Content/HTMLFileWebView.swift`), `HTMLLinkPreviewView` (`Intent/Views/Conversation/Content/HTMLLinkPreviewView.swift`), `MermaidWebView` (`Intent/Views/Conversation/Content/MermaidWebView.swift`)

## Context

Agents write HTML reports into the workspace, and the app shows them in a
`WKWebView`. The markup is untrusted. A report can reference relative images,
stylesheets and fonts that live next to it in the workspace.

## Decisions

### 1. The report is an inert document, not a browser

Applies to: `HTMLFileWebView`, `HTMLFileWebView.Coordinator.initialLoadURL`, `HTMLLinkPreviewView`

The web view runs no scripts and makes no network requests or navigations.
Relative images, stylesheets and fonts load only from the report's own
workspace.

1. `path` is the location of `file`, workspace-relative or absolute. Relative
   subresources resolve against it.
2. `initialLoadURL` is the one navigation the page allows: its own initial
   load. It is cleared once allowed.
3. The page prefix (CSP, DNS prefetch off, viewport) precedes all untrusted
   markup, including any attacker-supplied CSP or `<base>`. Inline styling,
   data images and the report's own relative images, stylesheets and fonts
   work. Scripts, frames, forms and every other load are denied.
4. `HTMLLinkPreviewView` fails closed. It never mounts untrusted HTML without
   its resource blocker (`HTMLFileWebView.blockingRules()`).

### 2. WebKit only calls the async navigation delegate method

Applies to: `HTMLFileWebView.Coordinator.webView(_:decidePolicyFor:)`, `MermaidWebView.Coordinator.webView(_:decidePolicyFor:)`

WebKit only calls the async form of this delegate method. That is why both
coordinators implement it as `async` and disable the `async_without_await`
lint rule on it.

### 3. Resource rules are pure and kept apart from WebKit

Applies to: `HTMLFileResourcePolicy`

`HTMLFileResourcePolicy` decides which subresources a report may load, and
from where. The rules are pure and kept apart from WebKit, so path resolution
and limits are unit-testable.

1. `scheme` (`intent-file`) is a private scheme for the report's base URL.
   WebKit never handles it itself.
2. `baseURL(host:filePath:)` builds the base URL for a report at `filePath`
   (workspace-relative, or absolute with a leading `/`) on a per-page `host`,
   so another page's URLs never resolve here.
3. `resource(for:host:root:)` returns the daemon path and type that a resolved
   subresource URL may load, for a page rooted at `root`.
4. `Kind`: images, stylesheets and web fonts only. No scripts, frames, media or
   documents.
5. `pathSegments` accepts plain names only. `..`, separators and control
   characters never reach the daemon.
6. `validate(_:as:)`: bytes must match the declared type, so a renamed HTML
   file never loads as an image. `fontSignatures` holds the leading signature
   for each font MIME type (TrueType has two).
7. `contentSecurityPolicy` allows inline styles plus this scheme's images,
   stylesheets and fonts. Scripts, frames, media, connections, forms and
   `<base>` stay denied.

### 4. The root mode fixes where subresources may resolve

Applies to: `HTMLFileResourcePolicy.Root`, `HTMLFileResourceHandler.root`

`Root` records how the report was addressed. Each mode has its own first path
segment, so a relative URL that climbs above it (or an absolute `/x.png`) no
longer starts with it and is rejected. A workspace-relative report can never
reach an absolute path, or the reverse.

1. `absolute`: a report opened by an absolute path or `file://` URL. Assets are
   sent as absolute paths, and the daemon still rejects any outside the
   workspace.
2. `workspace`: a workspace-relative report. Assets are sent as
   workspace-relative paths.

The handler's `root` is the current page's mode. Its subresources must resolve
under the same root.

### 5. Byte and request limits

Applies to: `HTMLFileResourcePolicy.maxResourceBytes`, `maxPageBytes`, `maxPageRequests`

`maxResourceBytes` is 4 MiB, `maxPageBytes` is 16 MiB and `maxPageRequests` is
64. Report screenshots are well under these. The limits bound transfer and
memory.

### 6. The scheme handler reserves each load's limit before fetching

Applies to: `HTMLFileResourceHandler`, `reserve()`, `admit()`, `servedBytes`, `reservedBytes`, `waiters`, `pageGeneration`, `beginPage(filePath:)`, `cancelAll()`

`HTMLFileResourceHandler` serves a report's relative images, stylesheets and
fonts from its own workspace through the daemon's file read, which still
enforces workspace containment. WebKit calls `WKURLSchemeHandler` on the main
thread, so MainActor isolation is correct here.

Each load reserves its whole byte limit before fetching, so in-flight plus
delivered bytes never exceed the page cap (`servedBytes` plus
`reservedBytes`). A load that finds the room only reserved, not yet used, by
loads in flight waits in `waiters`, first in first out, until one finishes and
releases its unused reservation. When a load ends it releases its reservation
and keeps only the delivered bytes. Loads are rejected only once delivered
bytes alone have spent the page budget, or the request cap is hit.

1. `admit()` returns the next load's limit, reserved, when the page has room
   for it now; a rejection once delivered bytes have spent the budget; or nil
   while only reservations hold the room.
2. `pageGeneration` increments per page, so a previous page's late completion
   never touches the new budget. `beginPage` cancels the previous page's
   loads, starts a fresh per-page budget and returns the page's base URL.
3. Stopping a task also takes a waiting load out of the queue. `cancelAll()`
   cancels every load and empties the queue; waiting loads end without
   fetching.
4. WebKit raises an exception if a stopped task receives anything, so a load
   delivers only while its task is still registered and not cancelled.
