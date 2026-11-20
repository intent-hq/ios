# 0048. Note detail, note links and task metadata

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

A note opens from the note list, a link in another note, or a link in a conversation. The daemon sends the note list as slim rows without content (PROTOCOL §5.2) and the body through a separate read, which can be cut for large notes. Task notes carry metadata (status, assignees, relations) that the desktop shows in `NoteMetadataBar.svelte`. ADR 0065 owns checkbox syntax and row icons.

## Decision

1. **Content rendering.** `NoteContentView` interleaves Markdown, Mermaid diagrams and native task rows, as the desktop `TaskItemNodeView` does.
   1. A plain checkbox row cycles todo → in-progress → done → todo on tap.
   2. A linked-task line is a bordered card with the live status icon, a status menu and the task title. Tapping opens the task note.
   3. Status menus offer the eight task-note statuses of PROTOCOL §5.4 and write the wire word.
2. **Which body to render** (`displayNote`).
   1. The store's cached note wins, so optimistic task-status edits show at once.
   2. A cached slim row has no content and a cut row has only a prefix. When the fetched body holds at least as much, it is grafted onto the cached row; the cached metadata still wins. When the list lands after `loadNote()`, the fetched body is grafted onto its slim row, so optimistic checkbox edits work on cached content.
   3. A slim row at a different revision than the fetched body means the note changed between the two reads. The view refetches; `fetchNote`'s upsert clears the stale marker and ends the cycle. Until then the view shows the last known content.
   4. A rendered note is never blanked. A transient refetch error keeps the last known content.
3. **Removal.** When the open note disappears from the workspace note list while content is loaded, the view refetches to confirm. An empty list also triggers the refetch, because the last note may have been the open one. Only a definitive not-found navigates away, to the workspace detail, so a spurious empty publish is harmless.
4. **Live updates.** The view refreshes on note events for as long as its task runs. SwiftUI cancels the task when the view disappears, which ends the stream, so the store never holds the view and no stale refresh runs after dismissal (ios#250). The view also observes agent events, so assignee names stay current.
5. **Truncated notes.** When the daemon cut a note too large for one read and the rest could not load (PROTOCOL §5.2 "Bounded note and comment reads"), `NoteTruncationNotice` shows above the body with the shown and total size, and offers a retry of the whole read.
6. **Note links.** `parseIntentNoteLink(_:)` accepts `intent://local/task/{id}`, `intent://local/note/{id}`, and the workspace-qualified `intent://local/{workspaceId}/task/{id}` and `intent://local/{workspaceId}/note/{id}`. A qualified link navigates in its own workspace; a short link uses the current one. The view fetches the note list so link titles resolve.
7. **Task metadata header** (desktop `NoteMetadataBar.svelte`).
   1. It shows for every task note except the spec. It also keeps metadata-only task notes (empty content) on the detail view instead of the "content unavailable" placeholder.
   2. Rows: status (interactive), assigned agents, and relation chips (depends on, depended on by, conflicts with). Empty rows are hidden. Chips navigate to the related note.
   3. Depended-on-by edges are computed on the client, as on the desktop: non-archived task notes whose `dependsOn` includes this note, sorted by id. Archived notes are excluded, because the list hides them and opening one is not found.
   4. A depends-on chip shows the unmet highlight (an hourglass) only while the dependency is in `unmetDependsOn` and the task is not complete.
   5. Assignees are deduplicated in first-seen order, then sorted by agent creation date, oldest first. Agents without a date sort last in wire order.
   6. Relation chips match the desktop `TaskRelationLink.svelte`: a live status icon for dependencies, a warning triangle in the shared amber for conflicts.

## Code

- `NoteContentView`, `PlainTaskRow`, `LinkedTaskCardRow`
- `NoteDetailView`: `displayNote`, `loadNote()`, `refreshNote()`, `showsTaskHeader(_:)`, `navigateToNote(_:in:)`, `parseIntentNoteLink(_:)`
- `NoteTruncationNotice`: `message(shownBytes:totalBytes:)`
- `TaskMetadataHeaderView`: `dependedOnBy(noteId:in:)`, `showsUnmetDependency(_:note:)`, `sortedAssigneeIds`, `TaskRelationChip`
