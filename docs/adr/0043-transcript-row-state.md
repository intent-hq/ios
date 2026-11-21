# ADR-0043: Transcript row disclosure and tool result pairing

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `TranscriptDisclosureStore`, `TranscriptDisclosure` (`Intent/Presentation/TranscriptDisclosureState.swift`), `MessageBlockPartitioning.pairToolResults(_:)` (`Intent/Presentation/MessageBlockPartitioning.swift`)

## Decisions

### 1. Disclosure state is owned by the conversation

Applies to: `TranscriptDisclosureStore`

The conversation owns the disclosure state of its rows. Moving a row between
the lazy history and the eager tail therefore does not reset the reader's
disclosure choices.

### 2. Callers outside the transcript get local state

Applies to: `TranscriptDisclosure`

Standalone previews and non-transcript callers have no retained state in the
environment. They still get local `@State`.

### 3. Tool results are paired once per message

Applies to: `MessageBlockPartitioning.pairToolResults(_:)`

`tool_result` blocks are keyed by the id of the `tool_use` block they answer.
They are matched on `resolvedToolUseId` or `toolCallId`, and the first match
wins. The pairing is computed once per message over the whole raw block list,
not per render row, so each block row receives only its own result value
instead of the whole block array. A `tool_use` inside a response group still
finds a `tool_result` that lands after the closing tag.
