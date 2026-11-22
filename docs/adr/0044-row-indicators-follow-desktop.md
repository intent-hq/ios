# ADR-0044: Note and workspace row indicators follow the desktop

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `NoteRowIcon` (`Intent/Presentation/NoteRowIcon.swift`), `WorkspaceRowView.PrIndicatorModel`, `WorkspaceRowView.derivePrIndicator(workspace:monitors:)`, `WorkspaceRowView.legacyPillStatus(_:)` (`Intent/Presentation/WorkspacePrPillDerivation.swift`)
- Related issues: ios#1091 (removal of the legacy `prStatus` / `prNumber` fallback)

## Decisions

### 1. Note row icons mirror the desktop NotesPanel, plus the spec star

Applies to: `NoteRowIcon`, `NoteRowIcon.kind(for:notes:)`

The leading icon of a Context-tab note row follows the branch order of the
desktop sidebar's NotesPanel: task metadata status, then the linked-task
progress ring, then the doc icon (`document`, the fe `getNoteIcon` fallback,
a muted doc icon). iOS adds one rule: the spec/default note keeps its star and
shows the progress ring next to it when its content links task notes.

`kind(for:notes:)` resolves the linked-task IDs in the note's content against
`notes`. Pass the store's full note list, so the ring recomputes as task
statuses change.

### 2. A task note with children shows their aggregate status

Applies to: `NoteRowIcon.childrenDerivedStatus(for:notes:)`

This follows `hasChildrenStatus` in the fe NotesPanel (L450-462). A task note
with children shows an aggregate of its children's statuses instead of its
own: complete when all children are `complete`, notStarted when all are
`not_started`, otherwise inProgress. It compares raw wire statuses like the
fe. Archived children are excluded, because NoteStore hides them.

### 3. The PR pill follows the desktop `WorkspaceCard`

Applies to: `WorkspaceRowView.derivePrIndicator(workspace:monitors:)`, `WorkspaceRowView.PrIndicatorModel`

The metadata line shows the primary pill and a "+N" count. This is the FE
`WorkspaceCard` composition (PROTOCOL §6.9):

1. primary = `selectPrimaryPr` over `pullRequests` merged with the
   workspace's monitors;
2. the legacy `prStatus` and `prNumber` are used only when the pool is empty;
3. "+N" = `countOtherMonitors` against the primary's repo-qualified number.

Like FE `mapWorkspacePRs`, an empty or absent `pullRequests` falls back to the
single `activePullRequest` row before merging. A nil pill renders no pill,
which is the legacy behavior.

### 4. Only the four known legacy statuses render a pill

Applies to: `WorkspaceRowView.legacyPillStatus(_:)`

In the legacy `workspace.prStatus` fallback, only the four known wire strings
(`Merged`, `Open`, `Draft`, `Closed`) render a pill. Unknown values hide it, as
before.
