# ADR-0041: Workspace diff highlighting and row layout

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspaceDiffPresentation`, `WorkspaceDiffSyntax` (`Intent/Presentation/WorkspaceDiffPresentation.swift`), `WorkspaceDiffRows` (`Intent/Presentation/WorkspaceDiffRows.swift`)
- Related issues: ios#1092

## Decisions

### 1. Lexer sources depend on how much of the file is known

Applies to: `WorkspaceDiffPresentation.sources()`

Commit diffs keep the complete source. Working and staged diffs expose only
hunks, so lexer state starts fresh at each contiguous hunk side and never runs
across omitted lines.

The "No newline at end of file" annotation is display-only and is never
lexer input (ios#1092).

### 2. Source building and run mapping run off the main thread

Applies to: `WorkspaceDiffSyntax.highlight(_:path:dark:tokenize:)`

Building sources and mapping runs to rows scale with the file, so both run in
detached tasks off the main thread.

### 3. Rows are flattened with stable IDs

Applies to: `WorkspaceDiffRows`, `WorkspaceDiffRows.embeddedLineLimit`

Diff rows are flattened with stable IDs, so a lazy stack builds only the lines
on screen. Embedded diffs sit inside the scroll view of the commit view, so
they cannot build rows lazily; `embeddedLineLimit` (100) caps them.

### 4. Content width is measured on a shortlist

Applies to: `WorkspaceDiffRows.widthCandidates`, `columns(_:)`, `lineRowGaps`, `font(for:)`, `contentWidth(font:)`, `horizontalPadding`

The widest lines are measured with the real font. Column counts only
shortlist them (`widthCandidates` = 4). `columns` approximates monospaced
columns: tabs advance to the next 4-column stop, non-ASCII scalars (which
include wide CJK and emoji) take two, and marks and format scalars take none.
A line row is old number, new number, marker and content, which gives three
gaps (`lineRowGaps`). `font(for:)` is the UIKit equivalent of
`.system(.caption, design: .monospaced)` at the given size.

`contentWidth(font:)` includes the gutters, marker, gaps and the default
16 pt horizontal padding (`horizontalPadding`), so the horizontal scroller's
fixed width fits the widest line.
