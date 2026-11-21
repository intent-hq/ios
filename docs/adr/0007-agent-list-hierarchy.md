# 0007. Agent list hierarchy and order

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

The agent list shows delegated agents under their parent and floats agents that need the user. It must match the desktop and survive bad data from the daemon.

## Decision

1. **Parent.** An agent's parent is the non-empty canonical `parentAgentId`, else the non-empty legacy `createdByAgentId`, also when the wire parent is null. This matches the desktop `agentDelegationParentOf`.
2. **Tree.** The list flattens only expanded branches, keeps their order, and bounds cyclic data. It does not build SwiftUI views recursively.
3. **Order.**
   1. Agents that need the user come first: blocker (0), question (1), discussion (2), then the rest (3). This matches the desktop hover card.
   2. Then most recent activity first. Timestamps parse leniently, because the daemon sends RFC 3339 with and without fractional seconds, and string comparison orders these wrongly. Agents without a valid timestamp sort last, with the id as a stable tiebreak.
4. **Index.** `AgentListIndex` is built once per agent snapshot, not once per row.

## Code

- `AgentListViewModel`: `parent(of:)`, `visibleTree(_:)`, `attentionRank(_:)`, `byLastActivity(_:_:)`
- `AgentListIndex`
