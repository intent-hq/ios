# ADR-0028: Notes, tasks, and comment threads keep slim and truncated reads distinct from full content

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `Note` (`Intent/Models/Note.swift`), `WorkspaceTask`,
  `TaskDisplayStatus` (`Intent/Models/WorkspaceTask.swift`), `CommentThread`
  (`Intent/Models/CommentThread.swift`)

## Context

Notes arrive from `note.list` either as full rows or as slim projection rows,
and very large notes can be cut by the daemon. Task notes carry task metadata
and a status vocabulary that is open on the wire. The app must know when a
cached row needs its full body.

## Decisions

### 1. Task metadata fields on a note

Applies to: `Note.assignedAgentIds`, `dependsOn`, `conflictsWith`,
`unmetDependsOn`, `estimatedEffort`

These are the remaining `metadata.task` fields (PROTOCOL §5.2 and §5.4). All
are omitted on the wire when empty. They are an empty array or `nil` when
absent or when the note is not a task. `unmetDependsOn` is a daemon-computed
projection of the `dependsOn` entries that are not yet complete.

### 2. Slim and truncated rows

Applies to: `Note.contentPreview`, `Note.contentLength`, `Note.contentTruncated`,
`Note.contentBytes`, `Note.isContentStale`, `Note.needsFullContent`,
`Note.preview`

`contentPreview` and `contentLength` are the slim `note.list` projection fields
(PROTOCOL §5.2 `projection: "slim"`). Slim rows omit `content` and carry the
first 500 characters plus the total character count instead. Both are `nil` on
full rows.

`contentTruncated` is true when `content` is only a prefix of the note: the
daemon cut a row that was too large for one read (PROTOCOL §5.2 "Bounded note
and comment reads"), and the rest could not be read. `contentBytes` is the full
UTF-8 size.

`isContentStale` is true for a slim row whose full body has not been loaded:
the daemon reported a non-empty content length, but the local row has no
content. Full rows (no `contentLength`) and genuinely empty notes
(`contentLength == 0`) are never stale.

`needsFullContent` is true for both slim and cut rows. On a slim row, full
`content` still wins when the row carries it.

`preview` falls back to the daemon's `contentPreview` (first 500 characters)
because slim rows carry no `content`. That is enough for a one-line excerpt.

### 3. Copy helpers

Applies to: `Note.withBody(of:)`, `Note.withContent(_:)`, `Note.withTaskStatus(_:)`

`withBody(of:)` grafts a fetched body and its cut markers onto a cached list
row whose metadata should win. `withContent(_:)` and `withTaskStatus(_:)` serve
optimistic local updates.

### 4. Task status vocabulary

Applies to: `TaskDisplayStatus`, `TaskDisplayStatus.needsAttention`,
`Note.taskDisplayStatus`, `WorkspaceTask`

`TaskDisplayStatus` is the display treatment for the task-note status
vocabulary (PROTOCOL §5.4): `not_started`, `waiting`, `discussion_needed`,
`blocked`, `in_progress`, `review_required`, `complete`, `cancelled`. Task
statuses stay open strings on the wire. Unrecognized values fall back to
`.unknown` so newer daemons degrade gracefully. `blocked` and
`discussion_needed` are pending attention-request states
(`ws.agent.reportBlocker` and `requestDiscussion`). They get a distinct
treatment instead of being grouped with unknown, and `needsAttention` is true
for them: the task waits on the user instead of progressing.

The checkbox markers in note `content` are not affected. The wire checkbox
vocabulary is only `[ ]`, `[x]`, and `[/]`. `blocked` and `discussion_needed`
exist only in the task-note metadata status.

`WorkspaceTask` holds the canonical task facts for a workspace. It matches
`WorkspaceTask` from intentd and is returned by `task.list` and
`task.subscribe`.

### 5. Comment threads

Applies to: `CommentThread`

A comment thread is the summary returned by `comment.subscribe`. It maps to
`CommentThreadSummary` from intentd (`intent-core/src/model.rs`).
