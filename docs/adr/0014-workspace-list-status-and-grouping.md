# ADR-0014: Workspace list status, dots, and grouping

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspaceDisplayStatus`, `hasUnreadAttention(_:)`, `hasRunningAgents(_:)`, `showsWaitingDot(_:)`, `resolveDisplayStatus(for:)`, `WorkspaceListViewModel` (`Intent/ViewModels/WorkspaceListViewModel.swift`)
- Related issues: ios#462, intent-hq/intentd#743

## Context

The workspace list shows a status per workspace, status dots, and Recent, Repo,
and Status views. The daemon owns the status derivation; the app owns the
presentation.

## Decisions

### 1. Display status comes from the daemon's wire value

Applies to: `resolveDisplayStatus(for:)`, `WorkspaceDisplayStatus.init?(wireValue:)`, `WorkspaceDisplayStatus.unknown`

The status is resolved from the daemon-owned `displayStatus` wire value
(snake_case). The daemon always emits it, including on the lite
`workspace.subscribe` snapshot (intent-hq/intentd#743). An absent field renders
as `.notStarted`. A value this build does not know (a newer daemon's status)
renders as `.unknown`, neutrally, instead of being folded into another status.
The retired `"unread"` value from older daemons maps to `.idle`: unread is now
the workspace `attention` flag, drawn as a dot overlay, not a status.

### 2. Status order is presentation order

Applies to: `WorkspaceDisplayStatus.sortOrder`, `WorkspaceDisplayStatus.allCases`

`sortOrder` orders the Status view groups to match the FE sidebar status view:
attention states first, then a lifecycle progression (idle, not started, in
progress, complete, PR open, mergeable, queued, merged). It is not the daemon's
derivation precedence, which a workspace never needs here because it already
resolves to one status. Unknown values sort last. `allCases` is a stable
historical iteration order, independent of declaration order.

### 3. Colors follow the Figma legend

Applies to: `WorkspaceDisplayStatus.color`

PR queued and PR merged share Blue 600 in the Figma Status Colors legend.

### 4. Dots and their precedence

Applies to: `hasUnreadAttention(_:)`, `hasRunningAgents(_:)`, `showsWaitingDot(_:)`

- The blue dot is the server-owned unread attention flag. `review_required`
  and `none` do not count; only `unread` is cleared by opening the workspace (`workspace.markSeen`).
- The green dot is the daemon-reported activity `agent_running`. One predicate
  serves the row's green-dot overlay and the waiting-dot precedence check, so the two cannot drift apart.
- The grey static waiting dot is the orthogonal `waiting` flag (protocol 6.17).
  Precedence is running, then unread, then waiting: the waiting dot never
  outranks the green or blue dots. It is informational only and never feeds
  attention or badge escalation.

### 5. Grouping and collapse state

Applies to: `WorkspaceListViewModel.groupedByRepo`, `collapsedGroups`, `isGroupExpanded(_:in:)`, `toggleGroup(_:in:)`

- Repo groups are ordered by the activity time of each group's most recent
  member, which is its first member because `filteredWorkspaces` is already
  sorted. This is the same rule as the FE sidebar's `groupedByRepo`.
- `collapsedGroups` holds the group keys the user collapsed, per grouped view
  mode. They are persisted so the iPhone list and the iPad sidebar share them across launches.
- Searching always shows every group expanded so matches are never hidden.
  Toggling a group is a no-op while searching.

### 6. Load failure with nothing shown

Applies to: `WorkspaceListViewModel.loadFailureMessage`

The message appears when the first `workspace.list` read failed and nothing is shown (ios#462).

### 7. Caches keep SwiftUI subscribed

Applies to: `WorkspaceListViewModel.derivedWorkspaces`, `sortedWorkspaces(revision:includeArchived:)`

`derivedWorkspaces` reads every observable input even on a cache hit, so
SwiftUI stays subscribed. The cache storage itself must not publish changes
during a view read, so it is `@ObservationIgnored`. `sortedWorkspaces` prunes
removed workspaces from the activity-time cache; metadata-only updates keep their parsed keys.
