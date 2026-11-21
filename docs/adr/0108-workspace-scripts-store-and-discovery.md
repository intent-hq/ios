# ADR-0108: Workspace script starts settle before stop or remove

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspaceScriptStore` (`Intent/Services/WorkspaceScriptStore.swift`,
  `Intent/Services/WorkspaceScriptStore+Actions.swift`),
  `WorkspaceScriptRepository` (`Intent/Services/WorkspaceScriptRepository.swift`),
  `WorkspaceScriptDiscovery` (`Intent/Services/WorkspaceScriptDiscovery.swift`)

## Context

The workspace screen can discover, register, start, stop, and remove scripts.
Script RPCs mutate the host, so their order matters.

## Decisions

### 1. One store per workspace view

Applies to: `WorkspaceScriptStore`, `WorkspaceScriptStore.suspendObservation()`

`WorkspaceScriptStore` is owned by one workspace view, so only the launching
window presents its browser. While the store is cached offscreen in
`WorkspaceDetailStoresCache`, `suspendObservation` pauses background
subscriptions and reconnect refreshes and keeps the known definitions.

### 2. A sent start must settle before stop or remove

Applies to: `WorkspaceScriptStore.suspendObservation()`, `WorkspaceScriptStore+Actions.swift`,
`WorkspaceScriptStore.startTasks`

A previously sent start must settle before a stop or remove can win.
`suspendObservation` retires view actions but keeps sent starts until they
settle, so a later stop or remove still waits for them before it sends its
request. Reselecting a script whose start is in flight shares that request.

### 3. Authoritative status outranks an older list

Applies to: `WorkspaceScriptStore` runtime update, `WorkspaceScriptStore.revisions`

After the store applies an authoritative status, it bumps the workspace
revision, so a list captured before that status cannot restore old fields.

### 4. Registration checks every page

Applies to: `WorkspaceScriptRepository.register`

Registration reads every `script.list` page before it creates a script, because
a matching script on a later page must not be created again.

### 5. Discovery is pure and mirrors the desktop detector

Applies to: `WorkspaceScriptDiscovery`

`WorkspaceScriptDiscovery` is the pure counterpart of the desktop manifest
detector. Discovery never registers or runs a script. The desktop's remaining
substring categories all use command mode, so the default mode is `command`
(with `storybook` as `service`).
