# 0063. Tool row classification

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Each `tool_use` block renders as a compact row: icon, verb and subject. Providers name tools differently (MCP prefixes, Codex `mcp.<server>.<tool>`), and mid-turn blocks often carry only an ACP title because providers send `raw_input: null`.

## Decision

1. `ToolClassifier` is a pure classifier, separate from the row view, so it is unit-tested.
2. **Desktop parity.** Prose-title detection (`isProseTitle`), deferred-load recognition and the ACP title fallbacks match the desktop classifier. `deferredToolName` ports the desktop `cleanToolName`; other categories still use the iOS `cleanToolName` (intent-hq/ios#1090).
3. **Workspace API.** A `workspace_api` call is recognized by name (Codex spelling included) or by input shape (`code` + `summary`). It shows the human-readable summary, not the raw tool name.
4. **ACP title fallbacks.**
   1. Read and edit rows take the path from titles such as ``Read `src/foo.rs` ``. There is no end anchor, so multi-line titles match on the first line.
   2. A captured fragment is a path when it contains `.` or `/`, or when it is one backtick-quoted token (`LICENSE`, `Makefile`).
   3. Terminal rows take the verb and command from titles such as ``Run `cargo test` `` or `Kill terminal 5`.
   4. A prose title renders verbatim instead of the generic row. Titles shaped like tool names keep the cleaned-name fallback.
5. The generic fallback uses the tool name as verb and the first meaningful input as subject.
6. Compiled regexes are cached by pattern, because rows re-render often during a turn.

## Consequences

- A new tool family needs a branch in the classifier and a test; the row view does not change.

## Code

- `ToolClassifier`: `classify`, `cleanToolName`, `isProseTitle`, `isDeferredToolLoad`, `deferredToolName`, `isWorkspaceApiName`, `classifyFallback`
