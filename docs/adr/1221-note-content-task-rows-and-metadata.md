# ADR-1221: Note content task rows, metadata header, and note list rows

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `NoteContentView`, `PlainTaskRow`, `LinkedTaskCardRow` (`Intent/Views/Notes/NoteContentView.swift`), `TaskMetadataHeaderView`, `ChipVariant`, `TaskRelationChip` (`Intent/Views/Notes/TaskMetadataHeaderView.swift`), `NoteListView`, `NoteRowView` (`Intent/Views/Notes/NoteListView.swift`)

## Context

These views copy the desktop frontend ("fe") treatment of task notes.

## Decisions

### 1. Note content renders native task rows

Applies to: `NoteContentView`

Note content renders as interleaved markdown, Mermaid diagrams, and native task
rows (plain checkbox rows and linked-task cards). This matches the fe's
`TaskItemNodeView` treatment and replaces the old emoji marker substitution.
Linked notes resolve on the main actor; row providers only return prepared
values.

### 2. Callback contracts

Applies to: `NoteContentView.resolveNote`, `NoteContentView.onOpenTaskNote`, `NoteContentView.onSetLineStatus`, `NoteContentView.onSetTaskNoteStatus`

- `resolveNote` resolves a note id against the workspace note list, for the
  live linked-task title and status; nil when unknown.
- `onOpenTaskNote` opens a linked task note by id, on the same path as intent
  link handling.
- `onSetLineStatus` writes a plain checkbox line's status. Arguments: the
  1-based line, and "todo" | "in-progress" | "done".
- `onSetTaskNoteStatus` writes a linked task note's status. Arguments: the task
  note id, and a task-note status word (PROTOCOL §5.4 vocabulary).

### 3. Plain and linked task rows

Applies to: `indentPadding(_:)`, `PlainTaskRow`, `LinkedTaskCardRow`

Nested checkboxes indent about 6pt per leading whitespace column, capped. A
plain checkbox line is a tappable status icon cycling todo → in-progress → done
→ todo, plus the line's inline markdown text. A linked-task line is a bordered
card (fe `TaskItemNodeView` card layout): a live status icon with a status
menu, the task title, and tap to open. Its status is the linked note's live
status when resolved, else the checkbox marker as a fallback.

### 4. Status menus offer the 8 task-note statuses

Applies to: `LinkedTaskCardRow.statusOptions`, `TaskMetadataHeaderView.statusOptions`, `TaskMetadataHeaderView.onSetStatus`

Both status menus offer the 8 task-note statuses of PROTOCOL §5.4 and write the
wire word from that vocabulary.

### 5. Metadata header matches the fe's `NoteMetadataBar.svelte`

Applies to: `TaskMetadataHeaderView`

The header shows status (interactive), assigned agents, and relation chips
(depends on, depended on by, conflicts with). Rows with no data are hidden.
Relation chips navigate to the related note. `notes` holds all workspace notes,
for relation chip titles and statuses and for reverse edges. Names and
environment values resolve on the main actor, before the row provider.

### 6. fe-parity rules for relations and assignees

Applies to: `TaskMetadataHeaderView.dependedOnBy(noteId:in:)`, `TaskMetadataHeaderView.showsUnmetDependency(_:note:)`, `TaskMetadataHeaderView.sortedAssigneeIds`, `TaskMetadataHeaderView.resolveAgentCreatedAt`, `TaskMetadataHeaderView.truncatedId(_:)`

- Reverse dependency edges are computed client-side: non-archived task notes
  whose `dependsOn` includes the note id, sorted by id for a stable order.
  Archived notes are excluded, because the note list hides them and navigating
  to one is treated as not found.
- A depends-on chip shows the unmet highlight only when the dependency is in
  `unmetDependsOn` and the task itself is not complete; the highlight is
  suppressed once the task is complete.
- Assignee ids are deduplicated, keeping the first occurrence, then sorted by
  agent creation date (oldest first). Agents with no resolvable date sort last
  and keep their wire order. `resolveAgentCreatedAt` exists for this ordering.
- `truncatedId` is the short display fallback for an agent id that cannot be
  resolved.

### 7. Relation chips match fe `TaskRelationLink.svelte`

Applies to: `ChipVariant`, `TaskRelationChip`

A chip links to a related task note. It shows a live status icon (dependency) or
a warning triangle (conflict), the title, and an hourglass marker on unmet
dependencies. Conflict chips use the fe `text-warning` treatment, the shared
#f59e0b amber (`TaskStatusIconView.Palette.amber`).

### 8. Note list rows

Applies to: `NoteListView`, `NoteRowView`

In a note row, the chevron and the title have separate tap targets. Each
button's hit area expands into the row gap without changing the visible spacing
(`tapTargetPadding`). Short nested titles are centered on the checkbox; wrapped
titles keep their cap-top alignment. `allNotes` lets the row resolve live task
progress from the complete note list.
