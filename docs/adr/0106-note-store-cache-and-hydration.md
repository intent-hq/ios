# 0106. Note store cache, hydration and not-found

**Status:** Accepted (recorded 2026-11-20 from test comments)

## Context

`NoteStore` keeps one workspace's notes. The list comes as slim rows (PROTOCOL §5.2 projection `slim`) without bodies, and the detail view reads full bodies with `note.get`. List reads, body reads, live deltas and workspace switches can overlap, and note ids such as `spec` repeat across workspaces. A wrong merge shows an old body or tells the user a note was deleted when it was not.

## Decision

1. **Revisions win.** A body read never replaces a cached row at a newer revision and never clears its stale marker. The caller still gets the body it fetched. A response at the cached revision or newer replaces the row.
2. **Workspace identity.** A body for another workspace's note with the same id never touches the cache (`upsertFullNote(_:workspaceId:)` refuses it, also at the same revision).
3. **Slim rows.**
   1. `fetchNotes(workspaceId:)` asks for the slim projection. When the daemon rejects the parameter with -32602, it retries once without it.
   2. A slim row at the same `updatedAt` as a cached full row keeps the loaded body. A slim row at a different `updatedAt` cannot prove the body current, so the stale marker wins.
   3. A body fetched before the list landed is kept when the slim list arrives.
   4. The spec row is hydrated with `note.get` when it is stale, because its content links task notes (the progress ring). Other rows stay slim.
4. **Not found.** `fetchNote(noteId:workspaceId:)` reports `notFound` only for -32602 with `data.code == "not-found"` (PROTOCOL §3.3, §9). Plain -32602 (invalid params, or a daemon that omits `data`) and a transport timeout are errors, never deletion.
5. **Loading gate.** `hasLoaded` stays false until the first read succeeds. An empty successful list is a real empty state. A "Not connected" error while the socket is still connecting never flips to the empty state.
6. **Workspace switches.** `prepareForWorkspaceChange(to:)` is a no-op for the same workspace, so a re-appear does not flash the loading state. A different workspace resets the store at once, before any read runs. A read for the old workspace never marks the new one loaded and never replaces its notes. An older read that resolves while a newer one is in flight never publishes and never clears `isLoading`.
7. **Change stream.** `noteChanges()` registers synchronously, so no event delivered after the call is missed. `note:deleted` fires it (and `onNoteChanged`), so the detail view re-validates. A new note changes list membership but can never be the open note, so it does not refresh the open note. A cancelled consumer stops receiving events and does not keep the store alive (ios#250).
8. **Cancelled reads.** A fetch whose task was cancelled (the screen was dismissed) never publishes, even when the reply resumes it in the same main-actor turn (ios#250).
9. **Quiet refresh.** A refetch that returns an identical list does not assign `notes`, so the list does not rebuild under the swipe-back transition.
10. **Live state.** While the subscription is live, untagged legacy note events do not refetch. A reconnect while the view is offscreen must not leave a stale live subscription that makes resume skip installing a new handler. Deinit removes the event and subscription handlers (monorepo#2211, monorepo#2213).
11. **Paging (PROTOCOL §5.2, §6.9).** The `note.list` walk reads every page. When a paged snapshot fails, the store shows the partial first page rather than nothing, and resubscribes for a fresh snapshot; that resubscribe is not cancelled with the walk that triggered it. Optimistic edits keep the truncation markers of the body they edit.

## Consequences

- Deleting a note in the UI needs the daemon's explicit not-found code; an old daemon only ever shows an error.

## Code

- `NoteStore`: `fetchNotes(workspaceId:)`, `fetchNote(noteId:workspaceId:)`, `NoteFetchResult`, `upsertFullNote(_:workspaceId:)`, `prepareForWorkspaceChange(to:)`, `hasLoaded`, `onNoteChanged`, `noteChanges()`, `scheduleReconnect(generation:)`
- `Note`: `isContentStale`, `contentTruncated`
