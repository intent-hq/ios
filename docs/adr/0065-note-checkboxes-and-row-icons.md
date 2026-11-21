# 0065. Note checkboxes and row icons

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Note detail renders checkbox lines as native rows and writes status changes back with the daemon's `task.update` (PROTOCOL §5.4). The Context tab shows an icon per note that must match the desktop sidebar.

## Decision

1. **Checkbox lines.**
   1. Syntax is `- [ ]`, `- [x]` or `- [/]` at any indent. Only `-` bullets count: the daemon's line parser (`parse_dash_checkbox` in `note_ops.rs`) rejects `*`, so a `* [ ]` line stays Markdown instead of becoming a row whose write would fail.
   2. Line numbers are 1-based, as the `task.update` `line` parameter. One trailing carriage return from CRLF content is accepted.
   3. Uppercase `X` normalizes to `x`. A marker rewrite accepts only `todo`, `in-progress` and `done`, and only on a checkbox line.
   4. The first `[title](intent://local/task/{id})` link on the line links the task. Until that note resolves, the marker status is the fallback.
   5. Fences stay in Markdown segments, so diagrams share the reference context. Whitespace-only runs are dropped.
2. **Row icons.** Branch order mirrors the desktop `NotesPanel`: task metadata status → linked-task progress ring → document icon. iOS adds one rule: the spec/default note keeps its star and shows the ring beside it when it links task notes.
3. **Parent tasks.** A task note with children shows the aggregate of its children (desktop `hasChildrenStatus`): complete when all are `complete`, not started when all are `not_started`, otherwise in progress. Raw wire statuses are compared. Archived children are excluded.
4. Pass the store's full note list, so the ring updates as task statuses change.

## Code

- `NoteContentSegmenter`: `taskLine(from:lineNumber:)`, `replacingCheckboxMarker(in:line:status:)`
- `NoteTaskLine`: `markerStatus`, `LinkedTaskRef`, `NoteContentSegment`
- `NoteRowIcon`: `kind(for:notes:)`, `childrenDerivedStatus`
