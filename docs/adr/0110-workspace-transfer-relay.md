# ADR-0110: Workspace transfer never cancels a mutating RPC

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspaceTransferRelay` (`Intent/Services/WorkspaceTransferRelay.swift`),
  `WorkspaceTransferExport` (`Intent/Services/WorkspaceTransferExport.swift`),
  `WorkspaceTransferStore` (`Intent/Services/WorkspaceTransferStore.swift`)

## Context

A workspace transfer exports a workspace from one machine and imports it on
another. It stages data on both sides, so a cancelled step can leave orphaned
state.

## Decisions

### 1. One attempt owns its socket and staging IDs

Applies to: `WorkspaceTransferRelay`

A single attempt owns a temporary destination socket and all staging IDs.
Cancellation never cancels a mutating RPC, because its reply may hold an ID
needed for cleanup. Commit is an explicit point after which cancellation is
refused.

`run` returns a warning when the import succeeded but source finalization
failed.

### 2. Duplicate checks read every destination row

Applies to: `WorkspaceTransferRelay.destinationWorkspaceRows`

The relay reads every destination workspace row with bounded page reads,
because a duplicate can sit past the first page. A walk that cannot finish
fails closed.

### 3. Export events are registered before the export starts

Applies to: `WorkspaceTransferExport`

The event registration stays alive before the export starts. Terminal events
can arrive before the start reply; only the reply's export ID selects the
result.

### 4. The store owns the transfer task

Applies to: `WorkspaceTransferStore`

The store runs the relay in a task it owns, so the transfer survives a view
task's cancellation during commit.
