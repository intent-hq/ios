# ADR-0156: Workspace status image keying and loading

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspaceStatusImageLayout`, `WorkspaceStatusImageView` (`Intent/Views/Workspaces/WorkspaceStatusImageView.swift`), `WorkspaceDetailSupport` status row (`Intent/Views/Workspaces/WorkspaceDetailSupport.swift`)

## Context

A workspace can carry a status screenshot (PROTOCOL §5.1
`statusImageAssetId`). The front end shows it in `WorkspaceProgressCard.svelte`;
the app keeps parity with it. `WorkspaceStatusImageLayout` is a pure mapping:
which workspaces render the image in their detail header, and how the fetch is
keyed.

## Decisions

### 1. A blank asset id means no image

Applies to: `WorkspaceStatusImageLayout.normalizedAssetId(_:)`

The daemon omits the field until it is set and folds blanks to a clear. The
app mirrors that, so an empty id never reaches the loader.

### 2. The task key

Applies to: `WorkspaceStatusImageLayout.loadKey(workspaceId:assetId:attempt:)`

The key is the `.task(id:)` key. A replaced asset (a new content-addressed id)
or a retry tap re-runs the fetch. A removal unmounts the view entirely.

### 3. Mounting and loading

Applies to: `WorkspaceStatusImageView`

The view renders the screenshot as a square thumbnail, fetched through the
session's `WorkspaceFileImageLoader` asset path (`note.readAsset`). Callers
mount it only when `WorkspaceStatusImageLayout.assetId(for:)` is non-nil, so an
unset image leaves no gap. `loader` is an explicit override for tests and
previews; when nil, the window session's loader is used, falling back to the
shared loader. In the detail header the image leads the summary as a
thumbnail; accessibility sizes stack it above.

### 4. Superseded and cancelled fetches

Applies to: `WorkspaceStatusImageView.body`

A replaced asset re-keys the task, and a superseded fetch must never overwrite
the newer image, so the result is dropped when the task is cancelled. A
`CancellationError` means the view disappeared or the workspace changed
mid-fetch; it is not a failure.

### 5. The placeholder holds the square

Applies to: `WorkspaceStatusImageView.placeholder(_:)`

The placeholder holds the thumbnail's square, so the header neither jumps on
load nor looks broken on failure.
