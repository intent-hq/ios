# ADR-0186: App logging, conversation trace and launch options

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `AppLog` (`Intent/Utils/AppLog.swift`),
  `ConversationTrace` (`Intent/Utils/ConversationTrace.swift`),
  `LaunchOptions` (`Intent/Utils/LaunchOptions.swift`)

## Decisions

### 1. Lower log levels are debug-only

Applies to: `AppLog.Category`

`AppLog` is structured logging with debug-only lower levels. Release builds
compile out debug through warning. Error and fault stay active, with private
messages.

### 2. Conversation trace is opt-in and content-free

Applies to: `ConversationTrace`

Conversation trace is explicitly enabled diagnostics in both Debug and Release.
Details must contain only identifiers, counts, timings and fixed reasons, never
transcript content.

### 3. Launch flags are read once

Applies to: `LaunchOptions`

Launch arguments and environment are read once per process, so app code does not
query `ProcessInfo` for flags directly.
