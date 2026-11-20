# 0029. Workspace stores and creation

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Workspace screens show the list, changes, browser servers, files and creation drafts. Their stores share a connection and react to events while screens come and go.

## Decision

1. **Parsing.** `parseWorkspace(_:)` returns nil for rows without `id`/`title` and for the virtual Chief of Staff workspace (`Workspace.chiefWorkspaceId`), so both `workspace.list` and the live reconciler drop it.
2. **Changes (`WorkspaceChangesStore`).**
   1. `loadPhase` covers the snapshot read; a failed refresh keeps the rows and its message, and a shown failure stays through Retry and event refreshes until a read ends. Load More failures are separate (`pageFailure`).
   2. `refresh(workspaceId:)` replaces both lists together and cancels any event refresh's trailing pass. A later refresh, navigation or change event invalidates its result. Event refreshes use `CoalescedRead` and repeat until events settle.
   3. A rebase can move the boundary while a page loads; the bounded walk then restarts.
   4. `startObserving(workspaceId:)` installs the event handler before subscribing and seeds after the acknowledgement. If subscription setup fails, the one-shot snapshot and pull-to-refresh still work. Remote subscriptions do not survive a connection loss.
   5. `stopObserving(preservingSnapshot:)` invalidates pending reads synchronously, so a disappearing screen cannot be repopulated. A commit pushed over Changes keeps its repository and rows for Back.
   6. Rootless events invalidate the whole workspace; inventory events can change the selection. An inventory outage must not erase known roots or block the primary snapshot.
   7. `WorkspaceDiffLoader`: a root commit has no parent, so its files are additions against the empty tree.
3. **Browser servers (`WorkspaceBrowserStore`).** Sources are filtered first, so a dismissed script cannot take an unrelated tab during merging or reappear as a tab when it stops. Events that invalidate a list in flight coalesce into one trailing fetch instead of publishing the stale snapshot.
4. **Creation media (`WorkspaceCreationImages`).**
   1. Photos media belongs to the draft; videos stay on disk until the workspace exists.
   2. Compressed source reads and prepared draft memory are bounded independently of the daemon frame limit; `JSONSerialization` may also escape base64 slashes.
   3. Pasted bytes are snapshotted during the paste action, before the run loop returns, because lazy providers can fail later. Decode and downsample run off the main actor.
   4. The import gate is set synchronously, before any picker or paste task can yield to Create. Each batch is atomic. A cancelled import that finishes after a newer one changes nothing.
   5. `validateRequest(_:)` uses the same serializer and envelope as `ConnectionManager`, bounds the RPC id with `Int.min`, and leaves 1 MiB below the host's 40 MiB.
5. **Creation with videos (`WorkspaceCreationVideoSubmission`).** The first message waits until every video is uploaded. The submission is kept by the draft across dismissal and failure, including the server's workspace and agent identity. The prompt and images are validated before any workspace is created. Ordinary sends are not idempotent: a lost reply is only checked through the composer's recovery owner, never resent (protocol §5.5).
6. **Provider options (`WorkspaceProviderOptions`).** Host policy for creation forms. A refresh hides the previous choices until catalog, settings and authentication were all read. `load()` always revalidates on sheet open or retry, joining concurrent callers; failed or unsupported reads never fall back to the unfiltered auth list. A null enablement map means unset, a missing one is invalid, and numeric flags are rejected. Missing or null authentication is unknown, not signed out.

## Code

- `WorkspaceStore`: `parseWorkspace(_:)`
- `WorkspaceChangesStore`: `loadPhase`, `pageFailure`, `eventRefreshes`, `refresh(workspaceId:)`, `loadMoreCommits`, `startObserving(workspaceId:)`, `stopObserving(preservingSnapshot:)`, `handleEvent`, `refreshRoots`; `WorkspaceDiffLoader`
- `WorkspaceBrowserStore`: `refresh`, `fetch`
- `WorkspaceCreationImages`: `addPaste`, `addPhotos`, `validateRequest(_:)`; `WorkspaceCreationVideoSubmission`: `submit`, `sendOrCheckAttempt`
- `WorkspaceProviderOptions`: `load()`
