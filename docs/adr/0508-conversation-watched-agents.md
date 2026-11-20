# ADR-0508: Conversation watched agents: visibility and detail authority

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConversationWatchedAgents` (`Intent/Services/ConversationWatchedAgents.swift`)

## Context

A conversation shows the agents it watches (delegation groups and
subscriptions). Rows load detail only when they matter to the user.

## Decisions

### 1. Bundled rows never grant detail authority

Applies to: `ConversationWatchedAgents` subscription read

When a subscription snapshot is seeded, sparse field presence and each
participant's canonical workspace are kept. Bundled display rows never grant
detail authority.

### 2. Visibility is real viewport intersection, per window

Applies to: `ConversationWatchedAgents.setVisible(_:visible:consumer:)`

The view reports actual viewport intersection, not `LazyVStack` prefetch. Each
window owns its own interest; one disappearing window cannot cancel another.

### 3. Selection is an explicit detail interest

Applies to: `ConversationWatchedAgents.selectedAgent(_:)`

Selecting an unresolved placeholder is an explicit detail interest. It shares
the same backend and agent flight with visible rows and routes.

### 4. Activity is display data only

Applies to: `ConversationWatchedAgents.handleActivity(agentId:lastAgentResponse:digest:)`

Enriched activity is display data, never a reason to discover an offscreen
agent.
