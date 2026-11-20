# ADR-1405: The long conversation fixture exercises scrolling, delegation, and hydration

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `DemoFixtures` long-conversation members (`Intent/Demo/DemoFixtures.swift`, `Intent/Demo/DemoFixturesData.swift`, `Intent/Demo/DemoFixturesLongConversation.swift`, `Intent/Demo/DemoFixturesLongConversationRound.swift`, `Intent/Demo/DemoFixturesLongConversationHydration.swift`)
- Related issues: intent-hq/ios#304, #305

## Context

Most demo agents serve a short transcript for App Store screenshots. One
workspace and agent serve a long coordinator transcript so that scroll,
delegation, and hydration UI can be tested against `--demo-data`.

## Decisions

### 1. One workspace and one agent own the long transcript

Applies to: `DemoFixtures.longConversationWorkspaceId`, `DemoFixtures.longConversationAgentId`

`agent.list` for `demo-ws-flaky-tests` ("Deflake payment integration tests")
returns `longConversationAgents` instead of the default `agents`. That
workspace is not part of App Store screenshots 02–04. The `chat.subscribe`
snapshot and the `agent.getConversation` seek of `demo-agent-deflake` ("Test
Stabilizer", idle) serve `longConversationMessages`. Every other agent keeps
the 4-message `conversationMessages` used by App Store screenshot 03.

### 2. A chat subscription acks with a fixed id and owes a seq-0 snapshot

Applies to: `DemoFixtures.chatSubscriptionId(agentId:)`

A demo `chat.subscribe` acks with this `subscriptionId`. The seq-0 snapshot it
owes is routed through `subscriptionPush(for:params:)`.

### 3. The coordinator opens with a "Waiting for all (1/3)" footer

Applies to: `DemoFixtures.longConversationDelegateIds`,
`DemoFixtures.longConversationAgents`, `DemoFixtures.longConversationSubscriptions`

The delegate ids are listed in the order the sub-agents appear in the
transcript's agent-to-agent rows. `longConversationAgents` holds the single
top-level agent (the only foreground row on the workspace overview) plus its
three delegated sub-agents (`createdByAgentId`, background), which are the rows
of the "Waiting for all" footer. `agent.getSubscriptions` for the coordinator
(PROTOCOL §5.5) reports one `after_all` delegation group over all three, with
the first already complete. The conversation therefore opens with the
"Waiting for all (1/3)" footer under the transcript.

### 4. One scheduled hook fills the hooks row

Applies to: `DemoFixtures.longConversationHookName`, `DemoFixtures.longConversationHooks`

`hook.list` serves a single scheduled hook for `longConversationAgentId`
(PROTOCOL §5.40), mid-TTL. It renders as a chip in the hooks row above the
composer. The row's own label is "Running hooks".

### 5. The transcript is many screens tall with rows of widely varying heights

Applies to: `DemoFixtures.longConversationMessages` and its helpers

The transcript is coordinator-shaped and many screens tall on an iPhone, so
scroll-position UI (the "Go to End" button) and the LazyVStack cold-layout paths
(intent-hq/ios#304, #305) can be exercised. It has 16 handwritten user/assistant
exchanges with a generated delegation round between each pair: tool-call
groups, agent-to-agent report rows (`metadata.type == "agent_message"`),
multi-paragraph markdown, fenced code blocks, tables, and thinking blocks.

### 6. Fixed first and last sentences anchor UI tests

Applies to: `DemoFixtures.longConversationFirstSentence`,
`DemoFixtures.longConversationLastSentence`, `DemoFixtures.longConversationSuggestedPrompts`

The first (user) message opens with `longConversationFirstSentence`. The last
(assistant) message's rendered text ends with `longConversationLastSentence`,
followed only by the stripped `<!-- suggested-prompts -->` block that carries
`longConversationSuggestedPrompts`. The prompts let the transcript's prompt
rows, and the scroll transition when one is tapped, be exercised.

### 7. Each delegation round has nine rows of uneven height

Applies to: `DemoFixtures.longConversationRound(_:)`, `DemoFixtures.longConversationRoundTopics`,
`DemoFixtures.LongConversationRow`

The round inserted after handwritten exchange `round` has nine rows of
deliberately uneven height: a tool-call group, three agent-to-agent reports, a
delegation tool call, markdown replies with code fences, tables and a thinking
block, and one human follow-up. `longConversationRoundTopics` has one entry per
gap between handwritten exchanges. A `LongConversationRow` is a
`longConversationMessages` row before its id and timestamp are assigned.

### 8. Delegate rows carry agent-to-agent attribution twice

Applies to: `DemoFixtures.delegateRow(_:text:)`

A delegate row is a user-role row sent by delegate `index`. It carries the
PROTOCOL §5.5 agent-to-agent attribution on the row metadata and on the text
block's `messageMetadata`.

### 9. Slim tool rows have two layouts and hydrate to a long listing

Applies to: `DemoFixtures.LongConversationSlimToolRowLayout`,
`DemoFixtures.longConversationFullOutput(for:)`

In `leading`, the tool blocks open the assistant's text message, matching a
coordinator turn on the daemon. In `standalone`, the tool blocks occupy their
own assistant message immediately before the related text message, which makes
the row independently tappable. The hydrated output is a multi-screen numbered
listing that expands the tool row after hydration.
