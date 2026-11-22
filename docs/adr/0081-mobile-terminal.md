# ADR-0081: Mobile terminal store and connection

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `MobileTerminalStore` (`Intent/Services/MobileTerminalStore.swift`), `MobileTerminalConnection` (`Intent/Services/MobileTerminalConnection.swift`)

## Decisions

### 1. Errors are keyed by workspace

Applies to: `MobileTerminalStore.errors`

A background refresh of one workspace must never surface an error on another
workspace's screen.

### 2. Process names are not persisted; custom names are, and win

Applies to: `MobileTerminalStore.processes`, `MobileTerminalStore.customNames`,
`MobileTerminalStore.title(for:)`, `MobileTerminalStore.rename(_:to:)`

`processes` holds running programs by terminal id. It is not persisted and is
refreshed from `terminal.list`. `customNames` holds the names the user chose,
and they win over program names. The title is the user's name, else the
running program, else the last program, else the terminal's own name.
`rename` with an empty name returns the terminal to automatic naming. It is
ignored for an ended terminal or a stale handle to a reused id.

### 3. A created terminal is recorded even if the connection changed

Applies to: `MobileTerminalStore` terminal creation (`terminal.create`)

A returned id means the shell is running on the daemon. The store records it
even if the connection changed meanwhile, because dropping it would orphan the
PTY.

### 4. A process event newer than a list row wins

Applies to: `MobileTerminalStore` reconcile (`terminal.list`)

When a terminal's own process event arrived during the `terminal.list`
request, that event is newer than the row, and the row is skipped.

### 5. Replay merges the snapshot with buffered stream output

Applies to: `MobileTerminalConnection.replay(snapshot:pending:)`

The buffer and the stream overlap while a snapshot request is in flight, so
replay drops the pending prefix that the snapshot already ends with.
