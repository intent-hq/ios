# ADR-0214: Script, monitor, hook, and terminal models keep server values and model only what the app shows

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `BackgroundHook` (`Intent/Models/BackgroundHook.swift`),
  `ScriptMonitorSummary`, `ScriptMonitorDetail` (`Intent/Models/ScriptMonitor.swift`),
  `WorkspaceScript` (`Intent/Models/WorkspaceScript.swift`),
  `MobileTerminalProcess` (`Intent/Models/MobileTerminal.swift`)

## Context

Agents can schedule background hooks, run workspace scripts, watch script
output with monitors, and use terminals. The app shows their state. The daemon
sends these through list reads and event payloads that do not always carry
every field.

## Decisions

### 1. Background hooks

Applies to: `BackgroundHook`, `BackgroundHook.State`

`BackgroundHook` is the wire `Hook` shape (PROTOCOL §5.40, v3.1).

- `code` arrives on `hook.list` only. `hook:*` event payloads never carry it,
  so event folds must copy the existing hook to keep it.
- `lastLogs` and `lastState` are deliberately not modeled. The display does not
  need them, and clients read them through `hook.list`.
- `State` is the hook lifecycle (PROTOCOL §5.40). `scheduled` and `running` are
  the active states. `dispatched`, `evicted`, `cancelled`, and `expired` are
  terminal.
- `expiresAt` is the TTL deadline (v3.1). It is absent only on pre-TTL legacy
  rows.
- `perpetual` hooks re-arm after a dispatch instead of retiring (v6.0). The
  field is always present on the wire from v6.0 and defaults to false when
  absent.

### 2. Script monitors

Applies to: `ScriptMonitorSummary`, `ScriptMonitorDetail`

`ScriptMonitorSummary` is active observation metadata, separate from a
script's runtime status. Its `createdAt` and `expiresAt` keep the server text:
an invalid date renders as unavailable, never as a guessed deadline.

Only an explicitly selected active watch loads the full trigger configuration
(`ScriptMonitorDetail`). The detail builds its own output pattern preview to
match the wire preview's UTF-8 bound without splitting a Unicode scalar or
executing the regex.

### 3. Script runtime snapshots clear absent fields

Applies to: `WorkspaceScript`

Runtime snapshots omit cleared fields, so absence must clear the old run's
values (`detectedURL`, `error`).

### 4. Terminal process names

Applies to: `MobileTerminalProcess`

The process names come from the daemon's `foregroundProcess` and `lastProcess`
fields. They are `nil` when the terminal has only ever run its shell.
