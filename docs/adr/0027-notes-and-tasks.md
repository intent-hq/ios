# 0027. Notes and tasks

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

`NoteStore` and `TaskStore` show a workspace's notes and tasks. Note bodies can be large. The stores use live-state subscriptions (ADR 0016) and keep cached data for read-only mode while a workspace is offscreen.

## Decision

1. **Load phase.** `loadPhase` covers the `note.list` read for the current workspace and resets on workspace change. A failure before any success shows an error with Retry, not "No notes". Only the first read shows loading. An identical refetch does not invalidate observers.
2. **Workspace switch.** Views call `prepareForWorkspaceChange(to:)` synchronously before the async fetch. `resetForFetchIfWorkspaceChanged(to:)` returns a new generation when the workspace changed (including the first), so the caller subscribes (ios#996). The subscribe runs after the list, like `onConnected()`; a later switch, reconnect or suspension bumps the generation, so only the last subscribes. Live-state subscription is owned by `onConnected()` and, on a switch, by `fetchNotes(workspaceId:)`.
3. **Reconnect fencing.** The connection observer records the generation when the state is sent, not when the queued delivery runs. Cancelling a Combine observer cannot cancel a reconnect task it already scheduled, so `scheduleReconnect(generation:)` fences both delivery and execution.
4. **Offscreen.** `suspendObservation()` pauses event, push and reconnect observation while the store is cached offscreen in `WorkspaceDetailStoresCache`, and keeps cached notes for read-only mode.
5. **Slim list (PROTOCOL §5.2).**
   1. `requestNoteList(workspaceId:)` uses `projection: "slim"`: rows carry `contentPreview`/`contentLength` instead of `content`, so note-heavy workspaces do not pull multi-MB frames. Every page is read; daemons without paging answer the whole list.
   2. If the daemon rejects the parameter (`-32602`), it falls back once to the full list. Pre-8.1 daemons ignore unknown parameters and serve full rows. Other failures propagate.
   3. `mergeSlimRows(_:)` keeps a cached full body at the same `updatedAt`; a re-list never clobbers loaded content. A slim row with a different `updatedAt` wins, and its stale marker makes content surfaces refetch with `note.get`.
   4. A stale spec is hydrated at once because its content links task notes.
   5. `upsertFullNote(_:workspaceId:)` grafts a fetched body onto a cached slim row: same workspace, same `updatedAt`, stale row only.
   6. A paged live snapshot is filled with `note.list` in the subscription's full projection. The previous list stays visible meanwhile.
6. **Single note (`fetchNote(noteId:workspaceId:)`).**
   1. `-32602` with `data.code == "not-found"` (PROTOCOL §3.3, §9) and archived notes mean gone. Any other error is transient, so network blips never look like deletion. A `-32602` without that code is logged loudly as a client bug.
   2. A not-found that races the caller's cancellation is transient.
   3. A note too large for one read is joined from `contentOffset` pages (§5.2). If that fails, the cut note returns with `contentTruncated`. A cut fetch never replaces a cached whole body of the same revision.
   4. It replaces a matching cached slim row, but never a newer row or a row from another workspace. `isCachedRowNewer(_:thanFetched:)` treats an unparseable timestamp as not newer.
7. **Order and tree.** `sortedNotes` puts the spec (`isDefault`) first, then `createdAt` ascending (oldest first), like Electron. Archived notes are excluded. `rootNotes` includes notes whose `parentId` is not among the current notes.
8. **Task status writes (PROTOCOL §5.4).**
   1. `updateTaskLineStatus(noteId:workspaceId:line:status:)` uses `task.update`, an atomic single-line edit. `line` is 1-based and `status` uses the checkbox vocabulary (`todo`, `in-progress`, `done`).
   2. `updateTaskNoteStatus(noteId:workspaceId:status:)` uses `task.updateNoteStatus` with the task-note vocabulary.
   3. Both apply optimistically and roll back on error. `rollback(_:)` restores only that note by id, so concurrent changes to other notes stay. The `note:updated` event reconciles the rest.

## Code

- `NoteStore`: `loadPhase`, `prepareForWorkspaceChange(to:)`, `resetForFetchIfWorkspaceChanged(to:)`, `fetchNotes(workspaceId:)`, `onConnected()`, `scheduleReconnect(generation:)`, `observeConnection(dropInitialState:)`, `requestNoteList(workspaceId:)`, `mergeSlimRows(_:)`, `upsertFullNote(_:workspaceId:)`, `isCachedRowNewer(_:thanFetched:)`, `fetchNote(noteId:workspaceId:)`, `NoteFetchResult`
- `NoteStore` (collections): `sortedNotes`, `rootNotes`
- `NoteStore` (live state, task status): `suspendObservation()`, `resumeObservation(workspaceId:)`, `fillSnapshot(reconciler:firstToken:)`, `updateTaskLineStatus(noteId:workspaceId:line:status:)`, `updateTaskNoteStatus(noteId:workspaceId:status:)`, `rollback(_:)`
