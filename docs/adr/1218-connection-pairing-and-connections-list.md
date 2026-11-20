# ADR-1218: Pairing finalization and the connections list

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConnectionPairing`, `ConnectionsView` (`Intent/Views/Connection/ConnectionsView.swift`)
- Related issues: ios#265

## Decisions

### 1. Finalizing a pairing names, saves, and activates the connection

Applies to: `ConnectionPairing.finalize(server:token:connection:persistence:)`

A successful pairing is finalized over the connection that was just
established. The connection is named after the daemon hostname (best-effort via
`host.status`), saved with an upsert, and marked active. `connection` is the
session connection the pairing was established over, so a pinned session names
and refreshes its own backend.

### 2. Display name order

Applies to: `ConnectionPairing.displayName(fromHostStatus:shared:)`

The name is `prettyHostname` (user-facing, for example "Clement's Mac Studio")
when present and non-blank, else `hostname`, else nil; the caller then falls
back to host:port. Values are trimmed so whitespace-only names never win. Older
daemons do not report `prettyHostname`. Shared connections prefer
`collaborationName`.

### 3. An unreadable registry is never overwritten

Applies to: `ConnectionPairing.PersistenceError.registryUndecodable`

When the existing saved-connections data cannot be read, the new pairing is not
written over it (intent-hq/ios#265).

### 4. Window-scoped connection state

Applies to: `ConnectionsView.windowConnectionId`

`windowConnectionId` is the connection this window's backend is bound to.
Under window model v2, "connected" badges and delete warnings are scoped to this
window, not to a global active pointer. It is nil in an unbound pairing window.

### 5. Open in New Window is iPad and visionOS only

Applies to: `ConnectionsView.supportsMultipleWindows`, `ConnectionsView.openInNewWindowButton(_:)`

The action opens a window pinned to the connection. `supportsMultipleWindows`
is false on iPhone, so callers gate on it and the action never appears there.

### 6. The list merges synced changes on appear

Applies to: `ConnectionsView`

On appear, the view pulls in registry changes synced from other devices while
the sheet was closed, then shows the merged list. Rows are prepared on the main
actor before SwiftUI requests them during async layout.
