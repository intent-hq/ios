# ADR-0805: Assistant views and the connection status block

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `AssistantView`, `AssistantHistoryMenu` (`Intent/Views/Conversation/AssistantView.swift`), `AssistantStateContent` (`Intent/Views/Conversation/AssistantStateContent.swift`), `ConversationConnectionStatusBlock` (`Intent/Views/Conversation/ConversationConnectionStatusBlock.swift`)
- Related issues: #745

## Context

The Assistant is a chat surface shown in a sheet or sidebar. It shows errors,
history and a loading state. Conversation loading surfaces share one inline
progress block.

## Decisions

### 1. A connection drop is not an Assistant error

Applies to: `AssistantView.errorBanner`

The error banner is hidden while the Assistant is remote read-only. A drop is
not an error; the read-only banner covers it.

### 2. `AssistantHistoryMenu` takes the coordinator as an explicit input

Applies to: `AssistantHistoryMenu.coordinator`

The explicit input survives native toolbar hosting, which does not inherit the
environment (#745).

### 3. The compact Assistant keeps its sheet and actions while loading

Applies to: `AssistantStateContent`

The compact Assistant keeps its sheet and actions while its thread list loads.

### 4. The caller owns the start date of the connection status block

Applies to: `ConversationConnectionStatusBlock.startedAt`

`ConversationConnectionStatusBlock` is the inline progress shared by
conversation loading surfaces. The caller owns the start date, so stage changes
and manual retries keep one elapsed clock. The elapsed text is hidden from
accessibility because VoiceOver announces it with the current step.
