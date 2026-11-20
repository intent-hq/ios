# 0006. Workspace list status, dots and groups

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

The daemon owns workspace status. It sends `displayStatus` as a snake_case wire value, plus separate flags for attention, activity and waiting. The iOS list must match the desktop sidebar and must not break when a newer daemon adds a status.

## Decision

1. **Status comes from the daemon.**
   1. `resolveDisplayStatus(for:)` maps `displayStatus`. The daemon always sends it, also on the lite `workspace.subscribe` snapshot (intent-hq/intentd#743). A missing field renders as `.notStarted`.
   2. A value this build does not know renders as `.unknown`, neutral, and sorts last. It is never folded into another status.
   3. The retired `"unread"` value from older daemons maps to `.idle`. Unread is now the `attention` flag, drawn as a dot.
   4. `allCases` has a fixed order. It does not follow declaration order, which SwiftLint sorts.
   5. PR queued and PR merged share Blue 600, as in the Figma Status Colors legend.
2. **Status grouping order** matches the desktop sidebar: attention states first, then idle → not started → in progress → complete → PR open → mergeable → queued → merged, then unknown. It is presentation order, not the daemon's derivation order.
3. **Dots.**
   1. Green: activity is `agent_running`. Blue: the `attention` flag is `unread`; `review_required` and `none` do not count, and only `unread` clears when the user opens the workspace (`workspace.markSeen`).
   2. Grey: the `waiting` flag (protocol 6.17). It is informational and never feeds attention or badges.
   3. Precedence: running > unread > waiting. The row overlay and the precedence check use the same predicates, so they cannot drift.
4. **Groups.**
   1. Repo groups are ordered by the activity time of their newest member, as in the desktop `groupedByRepo`.
   2. Collapsed groups persist per view mode, so the iPhone list and the iPad sidebar share them across launches.
   3. Search expands every group, so no match is hidden. Toggling a group does nothing while search is active.

## Code

- `WorkspaceDisplayStatus`: `init?(wireValue:)`, `allCases`, `sortOrder`, `unknown`
- `WorkspaceListViewModel`: `resolveDisplayStatus(for:)`, `hasUnreadAttention(_:)`, `hasRunningAgents(_:)`, `showsWaitingDot(_:)`, `groupedByRepo`, `collapsedGroups`, `isGroupExpanded(_:in:)`, `toggleGroup(_:in:)`

## Addendum: PR pill (recorded 2026-11-20 from code comments)

1. The metadata line follows the desktop `WorkspaceCard` (PROTOCOL §6.9). The primary pill is `selectPrimaryPr` over `pullRequests` merged with the workspace's monitors. An empty or absent `pullRequests` falls back to the single `activePullRequest` row before the merge, as in the desktop `mapWorkspacePRs`.
2. "+N" is `countOtherMonitors` against the primary's repo-qualified number.
3. The legacy `prStatus` / `prNumber` fields apply only when that pool is empty (intent-hq/ios#1091 tracks their removal).

- `WorkspaceRowView`: `derivePrIndicator`, `legacyPillStatus(_:)`, `PrIndicatorModel`
- `WorkspaceListRows`: `sorted`, `byRepo(_:)`, `visible` apply the group order above.
