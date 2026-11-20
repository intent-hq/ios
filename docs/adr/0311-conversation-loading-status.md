# ADR-0311: Conversation loading status timing and steps

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConversationConnectionStatusTiming` (`Intent/Presentation/ConversationConnectionStatusTiming.swift`), `ConversationConnectionStep` (`Intent/Presentation/ConversationConnectionStep.swift`)

## Decisions

### 1. Progress resets only the idle clock

Applies to: `ConversationConnectionStatusTiming`

A phase can be a transcript stage or a daemon startup phase. Progress (a phase
change) resets only the idle clock. Elapsed time always uses the
conversation's start date.

### 2. The delay notice hides before `onChange` arrives

Applies to: `ConversationConnectionStatusTiming.isDelayed(phase:at:)`

`isDelayed` compares the phase that the caller passes with the stored phase.
The notice therefore hides immediately on a new input, before SwiftUI delivers
`onChange`.

### 3. Loading steps are ordered

Applies to: `ConversationConnectionStep`

The steps are the ordered transcript-loading steps (`allCases` gives the
display order). The active row can show a more specific message.
