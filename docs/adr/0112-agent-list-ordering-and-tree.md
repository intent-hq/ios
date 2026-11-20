# ADR-0112: Agent list parents, orphans, and ordering

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `AgentListViewModel` (`Intent/ViewModels/AgentListViewModel.swift`), `AgentListIndex` (`Intent/ViewModels/AgentListIndex.swift`)

## Context

The agent list groups agents into foreground, background, delegated, orphaned,
and retired sections. Newer daemons report scoped counts and orphan
membership; older ones do not.

## Decisions

### 1. The index is built once per snapshot

Applies to: `AgentListIndex`

`AgentListIndex` is rebuilt once per agent snapshot, not once per rendered row.

### 2. Parent resolution matches the desktop

Applies to: `AgentListViewModel.parent(of:)`, `isRoot(_:)`

`parent(of:)` matches the desktop's `agentDelegationParentOf`: a nonempty
canonical parent, then a nonempty legacy creator, including when the wire
parent is null. Only a complete legacy response (`scopeCounts == nil`) can
infer a missing parent, which makes the agent a root.

### 3. Orphans

Applies to: `AgentListViewModel.orphanedAgents`

- With daemon-reported orphan membership, a restored parent can arrive while
  the orphan refresh is pending or failed. Stale membership must not duplicate
  its children: an agent whose parent is loaded is not an orphan. Cache absence
  alone never adds an orphan.
- Old scoped daemons (no `delegatedCounts.orphaned`) return the whole
  delegated bin. Its roots may have unloaded parents, or background parents in
  a collapsed bin, so both count as orphans.

### 4. Expansion is shareable

Applies to: `AgentListViewModel.Expansion`, `completedReveal`

`Expansion` records which sections are open, so another list of the same
workspace can match it. `completedReveal` is the selection whose sections a
sidebar list finished opening and loading.

### 5. The tree is flattened iteratively

Applies to: `AgentListViewModel.visibleTree(_:)`

Only expanded branches are flattened. The walk keeps ordering, bounds bad
cyclic data with a visited set, and avoids recursive SwiftUI view construction.

### 6. Attention first, then recent activity

Applies to: `AgentListViewModel.attentionRank(_:)`, `byLastActivity(_:_:)`

- Agents whose avatar state `needsUser` rank first: blocker (0), question (1),
  discussion (2). Every other state ranks last (3, `noAttentionRank`). This
  matches the cloudlands hover card, which groups attention rows above the rest.
- `byLastActivity` sorts by `bestTimestamp`, most recent first. Timestamps are
  parsed leniently because the daemon emits both fractional-second and
  whole-second RFC 3339 forms, which string comparison misorders. Agents with
  no parseable timestamp sort last, with the id as a stable tiebreak.
