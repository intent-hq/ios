# ADR-0222: Native browser navigation ownership, requests and presentation

- Status: Accepted
- Recorded: 2026-11-21 (moved from feature code comments)
- Applies to: `NativeBrowserNavigation`, `NativeBrowserTab`, `WorkspaceBrowser`, `NativeBrowserPresenter`, `ConnectionManagerReverseRequests`, `WorkspaceBrowserView`

## Decisions

Native tabs are logical sessions; only the presented session has a `WKWebView`.
Registry visibility and request acceptance do not prove page load or browser
automation support. Reject an entire mixed automation batch before opening a tab.

One foreground window owns presentation. Other windows sharing its backend
observe the registry without opening duplicate covers. Tab and web-view identity
remain stable across explicit navigation. Each explicit navigation has a fresh
request identity, including repeated URLs after a page follows a link or redirect.

An absent agent identity denotes the daemon's authenticated human operation.
Agents cannot mutate user-owned tabs or another agent's tabs. Reconciliation
walks every workspace-list page before pruning, and incomplete or superseded
reads cannot publish a partial full-sync snapshot. Serialize registry snapshots
so a delayed UI report cannot resurrect a closed tab.

Reverse request IDs are opaque: inspect the method before matching ordinary
numeric response IDs. Reply on the same socket; socket recovery owns transport
failures. Never replay a reverse request or response on a replacement connection.

## Verification

`NativeBrowserRequestTests` hosts the real browser view and page lifecycle with
a proxy returning a local blank page to avoid a network dependency. It checks
forwarded requests and stable web-view identity after in-page and repeated
explicit navigation. `NativeBrowserReconciliationTests` covers restored tabs on
later pages and failure before a complete reconciliation snapshot.
