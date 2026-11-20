# 0073. Screen restoration and route validation

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

The app saves the last screen per backend and restores it on launch. Several windows can show one backend. A restored or open workspace, agent or note can be deleted on another client, or while the app was disconnected. Validation reads are asynchronous and can finish after the user moved on.

## Decision

1. **Restoration claim.**
   1. Only the first window per backend session restores and saves that backend's screen (`claimScreenRestoration()`). Other windows start at the workspace list and never overwrite the saved screen.
   2. The claim is consumed lazily on first use (`restoresLastScreen`), so coordinators built for discarded SwiftUI view constructions never spend it. Pairing sessions have no backend and never restore.
   3. A user selection marks the backend (`markConnectionSelected(_:)`), so a new window's loading route is not mistaken for cold-launch restoration. The mark is never persisted. Raising an already attached window creates no coordinator, so the mark is not set for it (`prepareForSelection(to:route:)`).
   4. Restoring into a workspace counts as viewing it, like the desktop app.
2. **Workspace selection.**
   1. An explicit workspace tap always lands on the overview (ios#349). Saved sub-screens are restored only by cold-start restore (`restoreLastScreenIfAvailable`).
   2. Opening a workspace marks it seen (`workspace.markSeen`), which clears the server-owned unread dot on every client, like the desktop app.
   3. A completed row swipe opens the overview, then the most recently active non-retired agent (`onOpenRecentWorkspaceAgent(_:)`). The lookup reads every page of an unscoped `agent.list`, because the newest agents are on the last page (ios#943). A newer swipe or navigation supersedes the lookup.
3. **Validation.**
   1. Only a definitive not-found reads as deletion: JSON-RPC `-32602` with `data.code == "not-found"` (PROTOCOL §3.3, §9). Transient and transport errors leave the screen in place.
   2. A missing agent or note falls back to the workspace detail only when the window still shows that same agent or note. A stale validation never evicts a different screen in the same workspace.
   3. After a reconnect, the open agent is revalidated. Workspace validation follows from the reconnect's workspace fetch.
4. **Retained pages.** Leaving the remote UI (Home, Log Off, switching Mac) drops the retained workspace pages (`workspaceDetailStores`).
5. **Change viewer.** A transient change viewer route captures its repository (`WorkspaceChangeDestination`), so sidebar changes cannot retarget its diffs.

## Consequences

- Duplicated windows never fight over the saved screen.
- A slow validation cannot move the user away from a screen they opened later.

## Code

- `BackendSession`: `claimScreenRestoration()`
- `BackendSessionRegistry`: `markConnectionSelected(_:)`
- `BackendWindowSession`: `prepareForSelection(to:route:)`
- `AppCoordinator`: `restoresLastScreen`, `saveCurrentScreen()`, `onSelectWorkspace(_:)`, `onOpenRecentWorkspaceAgent(_:)`, `markWorkspaceSeen(_:)`, `validateRestoredAgent(agentId:workspaceId:)`, `validateRestoredNote(noteId:workspaceId:noteStore:)`, `handleMissingAgent(agentId:workspaceId:)`, `handleMissingNote(noteId:workspaceId:)`, `revalidateCurrentAgentAfterReconnect()`, `workspaceDetailStores`
- `WorkspaceChangeDestination`
