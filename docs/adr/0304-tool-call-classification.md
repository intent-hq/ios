# ADR-0304: Tool call rows are classified by name and input, like the desktop

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ToolClassifier` (`Intent/Presentation/ToolClassifier.swift`, `Intent/Presentation/ToolClassifier+Classification.swift`)
- Related issues: ios#1090

## Context

Conversation tool rows show a compact display for a `tool_use` block: an icon,
a verb and a subject. Providers name tools differently, and mid-turn blocks can
carry only an ACP title.

## Decisions

### 1. Classification lives outside the view

Applies to: `ToolClassifier`

The classification was extracted from `ToolCallView` so that the
classification path is unit-testable.

### 2. Prose ACP titles are detected like the desktop

Applies to: `ToolClassifier.isProseTitle(_:)`

A prose ACP title is human-readable, not a tool identifier. It is either
colon-prefixed, like "sub-agent-explore: Explore …", or has 3 or more words.
This mirrors the desktop classifier's `isProseToolName`.

### 3. A prose title is shown verbatim before the generic fallback

Applies to: `ToolClassifier.classifyFallback(_:)`

The fallback renders a prose `_acpTitle` verbatim instead of the generic
spanner row. Mid-turn blocks often carry only the title, because providers send
`raw_input: null`. The prose check keeps titles shaped like raw tool names on
the cleaned-name fallback.

### 4. `workspace_api` rows show a human-readable label

Applies to: `ToolClassifier.classifyWorkspaceAndReads(_:)`, `ToolClassifier.isWorkspaceApiName(_:)`

A `workspace_api` call prefers its human-readable label over the raw tool
name. The call is detected by name, or by input shape (`code` plus `summary`).
Codex names tools `mcp.<server>.<tool>`. That recognition is kept local to
`workspace_api`.

### 5. `_acpTitle` fallbacks extract paths and commands like the desktop

Applies to: `classifyWorkspaceAndReads(_:)`, `classifyFileMutations(_:)`, `terminalTitleInvocation(_:)`, `pathCandidate(_:)`

When the input has no path, the path is taken from the title, for example
"Read `src/foo.rs`" or "Edit `src/foo.ts`". The read pattern has no end
anchor, so multi-line titles match on the first line, like the desktop.
Terminal rows take the verb and command from titles such as "Run `cargo test`",
"Kill terminal 5" and "Launch `pnpm dev`" (desktop parity).

A captured fragment counts as a file path when it contains "." or "/", or when
it is a single backtick-quoted token. The second rule covers extensionless
file names such as "Read `LICENSE`" and "Edit `Makefile`".

### 6. Compiled regexes are cached by pattern

Applies to: `ToolClassifier.regexCache`, `ToolClassifier.firstCapture(_:in:group:)`

Compiled regexes are cached by pattern, because rows re-render often mid-turn.

### 7. Deferred tool loads use the desktop's name cleaning

Applies to: `ToolClassifier.isDeferredToolLoad(_:)`, `ToolClassifier.deferredToolName(_:)`, `ToolClassifier.cleanToolName(_:)`

Deferred-load recognition matches the desktop classifier, and
`deferredToolName` ports the desktop `cleanToolName`. Other categories still
use the iOS `cleanToolName`; aligning them is tracked in ios#1090.

### 8. The generic fallback shows the tool name and first meaningful input

Applies to: `ToolClassifier.classifyFallback(_:)`

When no category and no prose title applies, the row uses the tool name as
the verb and the first meaningful input value as the subject.

## Consequences

A new tool family needs a branch in the classifier and a test; the row view
does not change.
