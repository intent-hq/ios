# ADR-0026: The new-messages divider anchor is derived once per view model and never re-derived

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `NewMessagesDivider`, `NewMessagesDividerLatch`
  (`Intent/Models/NewMessagesDivider.swift`)

## Context

The conversation shows a presentation-only "New messages" divider after the
last message the user has seen. The daemon persists a per-session
`lastSeenMessageId` marker (PROTOCOL §5.5, `agent.markSeen`). It is served in
AgentLite and `agent.get` metadata and converges through `agent:updated`. Web
parity: `new-messages-divider.ts`.

## Decisions

### 1. The anchor is latched once at conversation entry

Applies to: `NewMessagesDivider.resolveAnchor(messageIds:lastSeenMessageId:)`,
`NewMessagesDivider.resolveLatchedAnchor(messageIds:latchedAnchorId:)`,
`NewMessagesDividerLatch`

On conversation entry (the `chat.subscribe` seq-0 snapshot), `ConversationViewModel`
derives the anchor once with `resolveAnchor` and latches it for the lifetime of
the view model. Rendering then uses only the latched anchor through
`resolveLatchedAnchor`, so later marker convergence never moves the divider.

`NewMessagesDividerLatch` records whether the view model has taken its one
entry-time anchor. A latched `nil` anchor means "entered, no divider", which is
different from unlatched.

### 2. When there is no divider at entry

Applies to: `NewMessagesDivider.resolveAnchor(messageIds:lastSeenMessageId:userMessageIds:)`

`resolveAnchor` returns the id of the message the divider renders after. It
returns `nil` (no divider, entry scrolls to the bottom as before) when:

- there is no marker;
- the marker is at the newest message, so nothing is unseen;
- the marker is the user's own message (`role == .user`). A send marks seen, so
  this is the common "sent, left, came back" case; everything below is the
  reply to that message, and a divider under it tells the user nothing;
- the marker dangles: its id is not in the transcript (for example the row was
  dropped by an `agent.editAndRegenerate` truncation).

### 3. A latched anchor is hidden, not re-derived, when it disappears

Applies to: `NewMessagesDivider.resolveLatchedAnchor(messageIds:latchedAnchorId:)`

The method returns the anchor id while it is still in the transcript. It
returns `nil` (divider hidden) when:

- the session latched `nil` ("session started, no divider"), so no divider may
  appear for the rest of the viewing session;
- the latched anchor is no longer in the transcript (for example dropped by an
  `agent.editAndRegenerate` truncation). The divider is hidden and the anchor is
  not re-derived.

### 4. Follow-to-bottom after the entry scroll depends on where the scroll landed

Applies to: `NewMessagesDivider.followDisabledAfterEntryScroll(distanceToBottom:atBottomThreshold:)`

The decision is evaluated after the initial scroll to the divider has settled.
It is the iOS translation of the web `dividerVisibleWhenScrolledToBottom`,
inverted.

`distanceToBottom` is the gap between the viewport's bottom edge and the end of
the content (`ConversationTranscriptScrollPolicy.distanceToBottom`). It is about
0 at the visual bottom. The entry scroll targets the divider row pinned to the
top of the screen. When the whole unseen tail fits on screen, the scroll clamps
at the bottom, the distance stays within the at-bottom threshold, and
follow-to-bottom stays enabled, as before. A larger distance means the viewport
really landed on the divider away from the bottom, so follow is disabled. The
threshold matches the list's existing at-bottom detection (distance <= 50,
`Constants.Conversation.Transcript.atBottomThreshold`).

A `nil` distance (scroll view not found yet) is unknown, not bottom. The scroll
targeted a divider with unread rows below it, so follow is disabled rather than
risking a later follow that pulls the user off it.

### 5. The seen marker moves only on proof of looking

Applies to: `ConversationViewModel.conversationAppeared()`,
`ConversationViewModel.conversationDisappeared()`, `agent.markSeen` callers in
`ConversationViewModel`

Entry never marks seen, so the divider anchor survives. A finished turn marks
seen after a short debounce, only while the conversation is on screen and the
app is active. A send marks seen only when it succeeds, as on the desktop:
composing is proof of looking, but a failed send delivered nothing.
`conversationDisappeared()` marks seen at once and cancels the debounce, so a
row that lands later is not marked. Every trigger goes through the store's
dedupe against the current marker.

