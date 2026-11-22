# ADR-0008: Screen navigation, last-screen restoration, and agent history

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `AppCoordinator` navigation (`Intent/App/AppCoordinatorNavigation.swift`), `AppCoordinatorNavigationState`, agent history (`Intent/App/AppCoordinatorAgentHistory.swift`), `WorkspaceChangeDestination` (`Intent/App/NavigationDestinations.swift`), `AppCoordinator.agentHistory` (`Intent/App/AppCoordinator.swift`)
- Related issues: ios#349, ios#943

## Context

The coordinator owns the window's current screen. It restores the last screen
on cold start, opens workspaces, agents, and notes, and validates restored
screens against the backend.

## Decisions

### 1. Only one window per session restores and saves the last screen

Applies to: `AppCoordinator.restoresLastScreen`, `saveCurrentScreen()`

Only the first window per backend session restores and saves that backend's
screen. Duplicated windows start at the workspace list. The claim is consumed
lazily on first use, so coordinators built for discarded SwiftUI view
constructions never spend it. Windows without the claim must not overwrite the
restoring window's saved navigation (spec decision 1b).

### 2. Opening a workspace marks it seen

Applies to: `AppCoordinator.restoreLastScreenIfAvailable()`, `markWorkspaceSeen(_:)`

Restoring into a workspace counts as viewing it, as in the FE.
`markWorkspaceSeen` sends `workspace.markSeen` without waiting. It clears the
server-owned unread attention flag (the blue dot) across clients. Failures are
logged and ignored: an older daemon without the method keeps its legacy behavior.

### 3. An explicit workspace tap lands on the overview

Applies to: `AppCoordinator.onSelectWorkspace(_:)`

An explicit workspace tap always lands on the workspace overview (ios#349).
Saved sub-screens are restored only by cold-start restore
(`restoreLastScreenIfAvailable`). Explicit agent and note selection and
notification routing go through `onSelectAgent` and `onSelectNote`.

### 4. A row swipe opens the most recent agent

Applies to: `AppCoordinator.onOpenRecentWorkspaceAgent(_:)`, `recentAgentLookupIsCurrent(_:workspaceId:)`, `AppCoordinatorNavigationState.recentWorkspaceAgentRequestId`

A completed row swipe opens the overview first, then the most recently active
non-retired agent. Ordinary row taps keep using `onSelectWorkspace`.

- The lookup uses unscoped reads, which include delegated and background
  agents. Every page is read, because the newest agents are on the last page
  (ios#943).
- The lookup owns navigation only while there is no newer swipe and the user
  is still on that workspace's overview. A `CancellationError` means a newer
  swipe or navigation superseded it.
- Navigation clears `recentWorkspaceAgentRequestId`, even when the user later
  returns to the same overview.

### 5. Only a definitive not-found evicts a restored screen

Applies to: `AppCoordinator.validateRestoredAgent(agentId:workspaceId:)`, `validateRestoredNote(noteId:workspaceId:noteStore:)`, `handleMissingAgent(agentId:workspaceId:)`, `handleMissingNote(noteId:workspaceId:)`, `handleMissingWorkspace()`

- Only a definitive not-found falls back. Transient and transport errors leave
  the screen in place; the conversation load re-validates.
- A definitive not-found is `-32602` with `data.code == "not-found"`
  (PROTOCOL §3.3/§9). A `-32602` without that code logs a warning and is not
  treated as deletion.
- `handleMissingAgent` runs when the viewed agent is no longer found: restore
  validation, not-found at conversation load, or deletion while open. It falls
  back to the workspace detail. It redirects only if the window still shows
  that agent's conversation, so a stale validation cannot evict a different
  conversation in the same workspace. `handleMissingNote` has the same guard.
- `handleMissingWorkspace` runs when a restored workspace is no longer in the
  list. The next workspace opens from the iPad auto-selection observer; only an
  empty list reveals the sidebar.
- Workspace validation runs on the first fetch after launch, also when that
  fetch returns no workspaces: it observes the fetch marker
  (`WorkspaceStore.lastUpdated`), not only the `workspaces` array. A publish
  before any successful fetch (`lastUpdated` still nil) is ignored.

### 6. Agent history records every route into a conversation

Applies to: `AppCoordinator.recordAgentVisit()`, `forgetHistory(ofWorkspace:)`, `socketReachesWindowDevice`, `visibleAgentHistory`, `AppCoordinator.agentHistory`

- `recordAgentVisit` records every route into a conversation: taps, restore, alerts, and history.
- A workspace reported deleted or archived is forgotten only when the report
  came from this window's own device. A sheet pairing can borrow the shared
  socket, and transfers keep workspace ids across devices.
- The socket describes this device only when it was admitted with the
  window's saved credentials (token and certificate fingerprint) and no
  pairing attempt owns it.
- History entries are offered only while their device is still saved.
- `agentHistory` is shared across windows and backends. Tests get one over their own persistence.

### 7. A viewer route captures its repository

Applies to: `WorkspaceChangeDestination`

A transient diff or commit viewer route captures its repository
(`gitRootId`), so sidebar changes cannot retarget its diffs.
