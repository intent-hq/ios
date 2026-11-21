# ADR-0319: Note checkbox lines are split out as native rows

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `NoteContentSegmenter`, `NoteContentSegment`, `NoteTaskLine`, `LinkedTaskRef` (`Intent/Presentation/NoteContentSegments.swift`)

## Context

The note detail view renders checkbox lines as native rows. This replaced the
older substitution of checkbox markers with emoji.

## Decisions

### 1. Only `-` checkbox lines become rows

Applies to: `NoteContentSegmenter`, `NoteContentSegmenter.checkboxLineRegex`

The segmenter splits note markdown into markdown segments and task-line
segments. The checkbox syntax is `- [ ]`, `- [x]` or `- [/]`, at any indent.
Only `-` bullets count: the daemon's `task.update` line parser (`note_ops.rs`
`parse_dash_checkbox`) rejects `*` bullets. A `* [ ]` line therefore stays
ordinary markdown instead of becoming a row whose status write would fail.
The regex groups are 1 = leading indent, 2 = marker, 3 = text after the
checkbox.

### 2. Fences stay in the markdown

Applies to: `NoteContentSegmenter.segments(for:)`

Fenced blocks stay in the markdown segment, so diagrams share its reference
context. Segments that hold only whitespace are dropped.

### 3. Line numbers follow the daemon protocol

Applies to: `NoteTaskLine.lineNumber`, `NoteTaskLine.marker`, `NoteTaskLine.linkedTask`, `NoteTaskLine.markerStatus`

`lineNumber` is the 1-based line number in the note content. It is the `line`
parameter of the daemon's `task.update` method (PROTOCOL §5.4). `marker` is
normalized to " ", "x" or "/" (uppercase "X" becomes "x"). `linkedTask` is the
first `[title](intent://local/task/{id})` link on the line.

One trailing carriage return from CRLF content is accepted on a checkbox
line.

`markerStatus` is the display status implied by the marker. Plain checkbox rows
use it directly. Linked-task lines use it as the fallback while their note is
not yet resolved in the workspace note list.

### 4. Marker rewrites accept only the three checkbox statuses

Applies to: `NoteContentSegmenter.replacingCheckboxMarker(in:line:status:)`

A local marker rewrite accepts only `todo`, `in-progress` and `done`, and only
on a line that is a checkbox line. Any other status or line returns `nil`.
