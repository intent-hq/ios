# ADR-0509: Daemon startup status scope and file highlight decoding

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `DaemonStartupStatus` (`Intent/Services/DaemonStartupStatus.swift`), `FileSyntaxHighlighter` (`Intent/Services/FileSyntaxHighlighter.swift`)

## Context

Two small services in this range each had one decision in a comment. They are
recorded together to avoid one-line records.

## Decisions

### 1. Startup status is owner-only and describes work only

Applies to: `DaemonStartupStatus`

The status is owner-only. A snapshot describes the daemon's startup work. It
never implies admission or authority.

### 2. Highlight runs decode off the main thread

Applies to: `FileSyntaxHighlighter.render(id:source:path:dark:)`

Decoding a large file's highlight runs takes tens of milliseconds, so
`FileSyntaxRun.decode` runs in a detached task instead of on the main thread.
