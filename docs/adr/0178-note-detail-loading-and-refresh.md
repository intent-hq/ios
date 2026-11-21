# ADR-0178: Note detail loading, refresh, and links

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `NoteDetailView` (`Intent/Views/Notes/NoteDetailView.swift`), `NoteTruncationNotice` (`Intent/Views/Notes/NoteTruncationNotice.swift`)
- Related issues: ios#250

## Context

The note detail view fetches one note's full body and also observes the
workspace note list. List rows can be slim (no content) or cut (a prefix only),
per PROTOCOL §5.2 "Bounded note and comment reads".

## Decisions

### 1. Inline back header on iPad

Applies to: `NoteDetailView.onInlineBack`

The iPad shell sets `onInlineBack`, and then shows an inline header in place of
the navigation bar.

### 2. Load order on appear

Applies to: `NoteDetailView.body`

1. Load the note.
2. Fetch all notes, so titles for `intent://` links resolve.
3. The list lands after `loadNote()`, so its slim row (§5.2) missed
   `fetchNote`'s upsert. Graft the fetched body onto it, so optimistic checkbox
   edits work off the cached content.
4. Fetch agents and observe their events. Agents back the metadata header's
   assignee names, so names stay current while the note is open.
5. Refresh on note events for as long as the task lives. SwiftUI cancels the
   task when the view disappears, which ends the stream. The store never holds
   a reference back to the view, and no stale refresh runs after dismissal
   (ios#250).

A note that could not load during a drop loads by itself on reconnect.

### 3. Live-delta removal is confirmed by a refetch

Applies to: `NoteDetailView.body` (`onChange(of: noteStore.notes)`)

When the open note vanishes from the note list while content is loaded, the view
confirms with a refetch, which falls back to the workspace detail on a
definitive not-found. An empty list also triggers the refetch, because the last
note in the workspace may have been the open one. A spurious empty publish is
harmless, because `refreshNote` only navigates on a definitive not-found.

### 4. A slim row at a different revision triggers a refetch

Applies to: `NoteDetailView.body` (`onChange(of: noteStore.notes)`)

A slim row (§5.2) with a different `updatedAt` than the fetched body means the
note changed between `loadNote()` and the list request. The view refetches so
the rendered content catches up. `fetchNote`'s upsert then clears the stale
marker, which ends the cycle.

### 5. The rendered note prefers the cached copy, with the fetched body grafted on

Applies to: `NoteDetailView.displayNote`, `NoteDetailView.refreshNote()`

The view renders the store's cached copy when there is one, so optimistic
task-status updates show at once; otherwise it renders the fetched note. A
cached slim list row (§5.2) has no content, and a cut list row has only a
prefix, so the fetched body is grafted onto it when the body holds at least as
much. The cached copy's metadata still wins. When the cached row is newer than
the fetched body, the view shows last-known content while the `onChange`
handler refetches. This is the same policy as `refreshNote`'s transient-error
path, which keeps the last known content: never blank a rendered note.

### 6. Task metadata header

Applies to: `NoteDetailView.showsTaskHeader(_:)`

The task-note metadata header renders for any task note except the spec. It
also keeps metadata-only (empty-content) task notes on the detail view instead
of the "content unavailable" placeholder.

### 7. Note-to-note navigation and link forms

Applies to: `NoteDetailView.navigateToNote(_:in:)`, `NoteDetailView.parseIntentNoteLink(_:)`

A non-nil target workspace id (from a workspace-qualified link) routes the
navigation to that workspace; nil falls back to the current one.
`parseIntentNoteLink` supports the short forms `intent://local/task/{id}` and
`intent://local/note/{id}`, and the canonical workspace-qualified long forms
`intent://local/{workspaceId}/task/{id}` and
`intent://local/{workspaceId}/note/{id}`. Long forms carry the embedded
workspace id. Short forms return nil for it, and callers fall back to the
current workspace. A resource word in the first slot is always the short form,
even when the next segment is also a resource word.

### 8. Truncation notice

Applies to: `NoteTruncationNotice`

The notice shows above a note whose body is only a prefix: the daemon cut a note
too large for one read, and the rest could not be loaded (PROTOCOL §5.2
"Bounded note and comment reads"). It offers a retry of the whole read.
