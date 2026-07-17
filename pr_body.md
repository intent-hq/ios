## Summary

Expands iOS agent-event handling to match cloudlands-fe by reacting to all 8 agent lifecycle event types on the legacy `events.event` firehose AND adopts the daemon's `subscription.push` snapshot/delta channels for workspaces when `server.capabilities.liveState` is advertised.

Fixes user report that agent activity from the desktop app is not reflected in the iOS workspace list.

Related workspace: https://app.intent.io/app/workspace/workspace-create

## Changes

### Part 1: Legacy path (unconditional)

- **WorkspaceStore.handleEvent** now reacts to all 8 agent lifecycle types:
  - `agent:started`, `agent:completed`, `agent:failed`, `agent:created`
  - `agent:deleted`, `agent:idle`, `agent:status-changed`, `agent:renamed`
- Unknown `agent:*` events are logged instead of silently dropped
- Each lifecycle event updates lastActivity high-water mark and triggers refetch (when not in live mode)

### Part 2: Live-state subscription adoption

- **ConnectionManager** calls `client.hello` on connect to detect `server.capabilities.liveState`
- **WorkspaceStore** subscribes to `workspace.subscribe` with `replaceGroup: "ios-workspaces"`
- Created **DeltaSubscription.swift** (Swift port of cloudlands-fe's `delta-subscription.ts`):
  - Parses `subscription.push` envelopes (`kind: snapshot/delta`, seq tracking)
  - Reconciles snapshots and deltas into id-keyed Map
  - Detects sequence gaps and triggers resnapshot
  - Gates legacy refetch when `live=true` to avoid double-apply

## Tests

- **WorkspaceStoreAgentLifecycleTests**: coverage for all 8 lifecycle event types
- **DeltaSubscriptionTests**: snapshot/delta reconciliation, gap detection, reset logic

## Out of scope (follow-up PRs)

- `note.subscribe`, `task.subscribe`, `comment.subscribe`, `chat.subscribe`
- Agent list live subscriptions (`agent.subscribe`)

## Verification

CI will run:
- `xcodebuild build-for-testing` (compilation check)
- `xcodebuild test-without-building` (unit tests)

Local verification was blocked by simulator unavailability, but Swift type-check passed.

## Review notes

- Do NOT merge without explicit approval
- Will address Copilot review comments when they arrive
