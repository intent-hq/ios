# 0069. Workspace diff rendering

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

The Changes tab and commit views render diffs with syntax highlighting and horizontal scrolling.

## Decision

1. **Lexer input.** Commit diffs keep complete source. Working and staged diffs expose only hunks, so the lexer starts fresh at each contiguous hunk side and never runs across omitted lines. The no-newline annotation is display-only and never lexer input (intent-hq/ios#1092).
2. Building sources and mapping runs to rows scale with the file and run off the main thread.
3. **Rows.** Rows are flattened with stable ids so a lazy stack builds only visible lines. Embedded diffs sit inside the commit view's scroll view and cannot build lazily, so they show at most `embeddedLineLimit` lines.
4. **Width.** Column counts (tabs to 4-column stops, non-ASCII scalars as two) only shortlist the widest lines; the shortlist is measured with the real font. Content width includes gutters, marker, gaps and the default 16 pt horizontal padding.

## Code

- `WorkspaceDiffPresentation`: `sources()`, `displayedContent`, `map`
- `WorkspaceDiffSyntax`: `highlight`
- `WorkspaceDiffRows`: `embeddedLineLimit`, `rows(limit:)`, `columns(_:)`, `contentWidth(font:)`, `horizontalPadding`
