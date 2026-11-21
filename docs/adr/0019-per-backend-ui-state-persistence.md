# ADR-0019: Per-backend drafts and screens migrate legacy values to the backend that owned them

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `PersistenceManager` (`Intent/PersistenceManager+Drafts.swift`,
  `Intent/PersistenceManager+Screens.swift`)

## Context

Before window model v2, drafts and the last viewed screen were stored in one
slot for the whole app. They are now keyed per backend. The old values must
move to the backend that was active when they were written, even though a
window can change the last-used pointer at any time.

## Decisions

### 1. The legacy draft owner is captured before the pointer changes

Applies to: `PersistenceManager.preserveLegacyDraftOwner()`,
`PersistenceManager.migrateLegacyDraft(workspaceId:agentId:backendID:)`

`preserveLegacyDraftOwner` captures the previous active backend before a window
changes the last-used pointer. The owner is remembered across connection
switches and process restarts. Missing or failed registry reads leave drafts
untouched until ownership resolves.

### 2. A scoped draft beats a legacy draft, and the legacy draft is always consumed

Applies to: `PersistenceManager.migrateLegacyDraft(workspaceId:agentId:backendID:)`

A scoped value is newer. The legacy value is removed even when it loses.

### 3. Legacy last-screen keys are read once for the active connection

Applies to: `PersistenceManager.loadLastScreen(for:)`, `PersistenceManager.lastScreenKey`
and the other single-slot keys

The single-slot keys (`lastScreen`, `lastWorkspaceId`, `lastAgentId`,
`lastAgentName`, `lastNoteTitle`, `lastNoteId`) predate window model v2. They
are read once as a migration fallback for the connection that was active when
they were written, then cleaned up.

### 4. Saved screen names and collapsed-group keys

Applies to: `PersistenceManager.SavedScreen.screen`,
`PersistenceManager.collapsedGroupsKey(for:)`

`SavedScreen.screen` is one of `"workspaceList"`, `"workspaceDetail"`,
`"conversation"`, or `"note"`.

The collapsed group keys are `workspaceListCollapsedRepoGroups` and
`workspaceListCollapsedStatusGroups`.
