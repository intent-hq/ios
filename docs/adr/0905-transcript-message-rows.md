# ADR-0905: Transcript message rows

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `MessageView`, `MessageRowContent` (`Intent/Views/Conversation/Transcript/MessageView.swift`), `ResponseGroup`, `ResponseGroupView`, `ResponseGroupBody` (`Intent/Views/Conversation/Transcript/ResponseGroupView.swift`), `AssistantMessageView` (`Intent/Views/Conversation/Transcript/AssistantMessageView.swift`), `UserMessageView` (`Intent/Views/Conversation/Transcript/UserMessageView.swift`), `ToolCallView` (`Intent/Views/Conversation/Transcript/ToolCallView.swift`), `EnvironmentValues.workspaceTranscriptDesign`, `WorkspaceUserBubbleLayout`, `WorkspaceThinkingLabel` (`Intent/Views/Conversation/Transcript/WorkspaceTranscriptDesign.swift`), `ConversationNoteSheet` (`Intent/Views/Conversation/Transcript/ConversationNoteSheet.swift`)
- Related issues: #904

## Context

Each transcript row renders one `ConversationMessage`. Rows re-render while a
reply streams, so they must avoid work that does not concern them. Many row
kinds follow the desktop front end (FE) for parity.

## Decisions

### 1. Rows and groups are thin shells over an equatable body

Applies to: `MessageView`, `MessageRowContent.==`, `ResponseGroupView`,
`ResponseGroupBody.==`

The transcript hands every row fresh closures on each evaluation. So
`MessageView` wraps `MessageRowContent` in `.equatable()`. The row body
re-renders only when its message, workspace, or hydration set changed, not on
every streaming delta.

`ResponseGroupView` does the same for one `<group:Name>` disclosure of an
assistant message. `ResponseGroupBody` re-renders only when its children,
paired tool results, position, workspace, or hydration set changed, not when a
streaming delta lands outside the group.

The manual `==` excludes the closures on purpose. The parent builds new ones
per evaluation, and they only capture stable identifiers.

### 2. Response group identity is deterministic

Applies to: `ResponseGroup.id`

A `ResponseGroup` is parsed from `<group:Name>...</group>` tags in assistant
text. The parser derives the id from the group's source: opening block id, a
per-block ordinal, and the name. Re-parsing identical input yields the same
identity, so streaming deltas do not reset the expansion state of a group that
is already on screen.

Render block ids from `groupContentBlocks` are deterministic too. A synthetic
segment id is the source block id plus the segment index. A still-open group
and the later closed group get the same id from the opening tag, the first
segment reuses the source block id, and a block without tags keeps its raw id
when a tag streams into it. Streaming never tears down a rendered row's view
state.

### 3. Message-derived values are computed once in `init`

Applies to: `AssistantMessageView.init`, `UserMessageView.init`

`AssistantMessageView` derives these once per message value in `init`, not on
every `body` evaluation: the prompt-stripped blocks grouped into render blocks,
the `tool_use` to `tool_result` pairing, and the copy-menu text.

`UserMessageView` does the same for the wake and agent attributions, the
partitioned blocks, and the copy-menu text. Its body also re-runs on the
expansion toggle.

### 4. Group inputs are narrowed to the group's own children

Applies to: `AssistantMessageView.groupInputs(_:)`, `ResponseGroupView.toolResults`,
`ResponseGroupView.hydratingBlockIds`

`toolResults` holds `tool_result` blocks keyed by the id of the `tool_use`
child they pair with. `AssistantMessageView` pairs them once per message. The
pairing and the hydration set are narrowed to one group's children and their
paired results. So the group's equatable gate sees only changes that concern
its own rows.

### 5. Prompt stripping rebuilds the block list

Applies to: `AssistantMessageView.body`

The block list carries `.id(hasStrippedPrompts)`. Cached markdown is rebuilt
when a streamed prompt block closes and disappears.

### 6. Slim rows hydrate on demand (PROTOCOL §5.5)

Applies to: `MessageView.hydratingBlockIds`, `ToolCallView.isHydrating`,
`ToolCallView.isTruncated`, `ToolCallView.onHydrate`, `ResponseGroupView.hydratingBlockIds`

A slim-served row has an input or output that is a bounded preview. Expanding
it triggers the on-demand full fetch through `agent.getMessageBlock`.
`hydratingBlockIds` holds the block ids of the message with a fetch in flight,
and the row passes them through to `ContentBlockView`. When `onHydrate` is
absent there is no hydration, and the bounded preview stays.

### 7. Rows report layout changes before disclosure

Applies to: `MessageView.onLayoutChange`, `ToolCallView.onLayoutChange`

`onLayoutChange` invalidates the transcript's settled row height before local
disclosure state changes the row's layout.

### 8. Notice rows are chosen before role branching

Applies to: `MessageRowContent.body`, `MessageRowContent.systemMessage`

1. A questions-dismissed row (PROTOCOL §5.5 `questions_dismissed`) renders as
   a compact divider chip, whatever its persisted role. FE parity:
   `ChatMessage.svelte`.
2. A model-change row (`metadata.type = "model_changed"`, PROTOCOL §5.5
   `agent.setModel`) is informational and renders as a centered divider chip,
   whatever its persisted role. FE parity: `ChatMessage.svelte` checks
   `getModelChangeNotice` before any role branching.
3. An event-notification wake row renders as a compact banner. The whole body
   is machine text, so the banner replaces the bubble. It is display-only. FE
   parity: `EventWakeupBanner`.
4. Attention-request and turn-failure system rows get a card for their kind.
   Every other system row falls back to a generic muted banner.

### 9. Agent and automated-wake rows start collapsed

Applies to: `UserMessageView.disclosure`, `UserMessageView.isAgentMessageExpanded`,
`UserMessageView.isAutomatedWakeExpanded`

Agent-to-agent rows start collapsed (FE parity: `ChatMessage.svelte`
`isAgentMessageExpanded`). Hook, PR, and script wake cards also start
collapsed (FE parity: `ChatMessage.svelte` `isAutomatedWakeExpanded`). The
disclosure state is owned by the row so its body tracks the state.

### 10. User text keeps the typed layout

Applies to: `UserMessageView.userDisplayText(_:)`, `UserMessageView.usesTrimmedMessageText`

User text is parsed as inline Markdown only, so typed line breaks and list
markers stay as written. A user row renders text first, then image and video
attachments as thumbnails, then file attachments as chips, whatever the block
order in the payload (`MessageBlockPartitioning.partitionUserBlocks`). Links keep the text color and read as links by
underline, as in replies (#904).

A plain bubble measures its existing padding from the cap top to the final
baseline. Attributed headers, chips, attachments, and multiple blocks keep the
native bounds between them.

### 11. The workspace transcript design is opt-in

Applies to: `EnvironmentValues.workspaceTranscriptDesign`,
`WorkspaceUserBubbleLayout`, `WorkspaceThinkingLabel`

Only the approved workspace transcript root opts in. Shared callers keep their
existing UI. `WorkspaceUserBubbleLayout` measures a trailing bubble against its
actual proposal, without fixed heights or screen-size reads.
`WorkspaceThinkingLabel` is the shared alignment for persisted thinking
disclosures and the live activity row.

### 12. Assistant-workspace note links push inside the note sheet

Applies to: `ConversationNoteSheet`

The note sheet opens from a transcript note reference. Note-to-note links that
target the hidden global Assistant workspace push inside the sheet. That
workspace has no place in the Workspaces tab, so the coordinator route would
replace the user's open workspace screen with it. Other links keep the
coordinator route.
