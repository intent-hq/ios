# 0035. HTML report viewer sandbox

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Agents write HTML reports into the workspace, and the phone shows them in a `WKWebView`. The markup is untrusted: an agent or a file it copied can contain scripts, a `<base>` tag, its own CSP, frames, forms, or links to other hosts and to files outside the workspace. A report also needs its own relative images, stylesheets and fonts, or it looks broken.

## Decision

1. **An inert document, not a browser.** `HTMLFileWebView` shows one document with no scripts, no network and no navigation.
   1. The app puts a `<meta>` CSP before all untrusted markup, so an attacker-supplied CSP or `<base>` cannot loosen it. The policy (`contentSecurityPolicy`) allows inline styles, `data:` images, and images, stylesheets and fonts from the private scheme. Scripts, frames, media, connections, forms and `<base>` stay denied.
   2. The only navigation allowed is the page's own initial load (`initialLoadURL`), once. Every other navigation is cancelled. The Mermaid page applies the same rule to its own page URL.
   3. A content rule list blocks `http(s):` and `file:` loads (`blockingRules()`). The preview fails closed: it never mounts untrusted HTML without the blocker (`HTMLLinkPreviewView`).
   4. WebKit calls only the `async` form of `webView(_:decidePolicyFor:)`. Both `HTMLFileWebView` and `MermaidWebView` implement that form; a completion-handler form would never be called, and navigation would not be checked.
2. **Subresources through the daemon.** `HTMLFileResourceHandler` serves subresources on the private `intent-file` scheme. WebKit never handles that scheme itself. Bytes come from the daemon's file read, which still enforces workspace containment.
   1. Each page gets its own `host` in its base URL (`baseURL(host:filePath:)`), so another page's URLs never resolve on it.
   2. `Root` records how the report was addressed. A workspace-relative report sends workspace-relative paths; an absolute or `file://` report sends absolute paths, and the daemon rejects any outside the workspace. Each root has its own first path segment, so a relative URL that climbs above it, or an absolute `/x.png`, no longer starts with it and is rejected. A workspace-relative report can never reach an absolute path, or the reverse.
   3. Path segments are plain names only. `..`, separators and control characters never reach the daemon.
   4. Only images, stylesheets and web fonts load (`Kind`). The bytes must match the declared type (`validate(_:as:)`), so a renamed HTML file never loads as an image.
3. **Byte budget.** Limits bound transfer and memory: `maxResourceBytes` per load, `maxPageBytes` per page, `maxPageRequests` per page. Report screenshots are far below them.
   1. Each load reserves its whole byte limit before it fetches, so in-flight plus delivered bytes never exceed the page cap (`servedBytes`).
   2. A load that finds the room only reserved by loads in flight waits, first in first out, until one finishes and releases its unused reservation. A load is rejected only when delivered bytes alone have spent the budget or the request cap is reached (`admit()`).
   3. `beginPage(filePath:)` cancels the previous page's loads and starts a fresh budget. `pageGeneration` keeps a late completion from the previous page off the new budget.
   4. A stopped scheme task never receives data, because WebKit raises an exception if it does.
4. **Isolation.** `HTMLFileResourcePolicy` is pure and kept apart from WebKit, so path resolution and limits have unit tests. `HTMLFileResourceHandler` is main-actor isolated, because WebKit calls `WKURLSchemeHandler` on the main thread.

## Consequences

- A report that needs scripts or remote assets does not render them. This is intended.
- A new subresource type needs a `Kind`, a byte signature check and a CSP change together.

## Code

- `HTMLFileWebView`: `blockingRules()`, `makeWebView(coordinator:rules:)`, `Coordinator.load(_:path:in:)`, `initialLoadURL`
- `HTMLFileResourcePolicy`: `scheme`, `Root`, `Kind`, `baseURL(host:filePath:)`, `resource(for:host:root:)`, `validate(_:as:)`, `contentSecurityPolicy`, `maxResourceBytes`, `maxPageBytes`, `maxPageRequests`
- `HTMLFileResourceHandler`: `beginPage(filePath:)`, `servedBytes`, `pageGeneration`, `admit()`, `cancelAll()`
- `HTMLLinkPreviewView`, `MermaidWebView`
