# ADR-1307: Formatting and parsing helpers that match the desktop app

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `DurationFormat` (`Intent/Utils/DurationFormat.swift`),
  `ISO8601DateFormatter` lenient parsing (`Intent/Utils/ISO8601+Lenient.swift`),
  `TaskStats`, `LinkedTaskLine`, `TaskContentParser` (`Intent/Utils/TaskStats.swift`),
  `workspaceActivityDisplayTime(_:)`, `isWorkspaceActivityMoreRecent(_:than:)`
  (`Intent/Utils/WorkspaceActivityTime.swift`)

## Context

Several small helpers port desktop (cloudlands-fe) logic so that iOS shows the
same values and order as the desktop app. They must keep matching the FE
behavior.

## Decisions

### 1. Compact durations follow `formatCompactDuration`

Applies to: `DurationFormat`

Compact duration rendering for the chip detail headers is the iOS counterpart of
cloudlands-fe's `formatCompactDuration` (en): at most two adjacent units
(d/h/m/s), a zero adjacent unit omitted (so a smaller remainder is truncated with
it), rounded to the nearest second, and negatives clamped to "0s".

### 2. Daemon timestamps parse with or without fractional seconds

Applies to: `ISO8601DateFormatter.withFractionalSeconds`,
`ISO8601DateFormatter.lenientDate(from:)`

Lenient ISO 8601 / RFC 3339 parsing is shared wherever the daemon may emit a
timestamp with or without fractional seconds (for example
`attentionRequestTimestamp`, and agent `createdAt`, `updatedAt` and
`lastActivity`). The formatters are cached because `ISO8601DateFormatter`
construction is non-trivial and they are reused on every parse. Example inputs:
"2026-07-30T10:00:00.500Z" and "2026-07-30T10:00:00Z".

### 3. Task stats are a local count that mirrors the FE

Applies to: `TaskStats`, `TaskContentParser`, `TaskContentParser.parseTaskStats(content:notes:)`

`TaskStats` is a per-note linked-task aggregate parsed from Markdown content. It
ports the FE's `parseTaskStats` (sidebar utils): a local count over
`[text](intent://local/task/{id})` links in one note. It is not the canonical
workspace-wide task-progress rollup, which the daemon owns (`task.list`).
`TaskContentParser` mirrors the FE's `TASK_LINK_REGEX_FLEXIBLE` and
`parseTaskStats`.

Classification matches the FE:

- cancelled tasks are excluded from the total entirely;
- complete counts as completed;
- in_progress and review_required count as in progress;
- unresolved IDs and all other statuses count toward the total only.

### 4. Task links never match across lines

Applies to: `TaskContentParser.taskLinkRegex`

The regex matches `[text](intent://local/task/{id})`; group 1 is the text and
group 2 is the id. Line terminators are excluded from both classes so an
unclosed link cannot consume a later line's `)` and match across lines.

### 5. Linked task lines support checkbox rendering

Applies to: `LinkedTaskLine`

A `LinkedTaskLine` holds enough line information for a renderer to replace the
line's checkbox. `lineRange` is the full line, excluding the line terminator.
`checkboxMarker` is the marker before the link (" ", "x", "/") when the line is a
checkbox list item, or nil when the line has no checkbox. An uppercase "X" in the
source is normalized to "x".

### 6. Workspace activity order mirrors the desktop sidebar

Applies to: `workspaceActivityDisplayTime(_:)`, `isWorkspaceActivityMoreRecent(_:than:)`

This mirrors cloudlands-fe's `workspace-activity-time.ts`. The activity time a
workspace sorts by is the first parseable of `lastActivity`, `createdAt`,
`updatedAt` (seconds since 1970), or 0 when none parses, so unstamped workspaces
sort last, exactly as in the desktop sidebar. `isWorkspaceActivityMoreRecent` is
the `sorted(by:)` predicate, most recent first: the FE's
`compareWorkspaceActivityDisplayTimeDesc`.
