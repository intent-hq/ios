# 0023. Workspace files and media

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

The app reads workspace files, images, PDFs and videos from the daemon and renders them. Decoding can be slow, and files can be large.

## Decision

1. **Off the main thread.** `FileSyntaxHighlighter` decodes a large file's highlight runs in a detached task; it takes tens of milliseconds.

## Code

- `FileSyntaxHighlighter`: `highlight(source:path:dark:)`
