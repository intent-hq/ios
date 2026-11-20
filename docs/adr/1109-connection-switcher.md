# ADR-1109: Connection switcher action, drawer gestures, and new windows

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `OpenConnectionSwitcherAction`, `ConnectionSwitcherOpenPreference`, `WorkspaceConnectionSwitcher` (`Intent/Views/Workspaces/WorkspaceConnectionSwitcher.swift`)

## Decisions

### 1. The environment action stores state, not a closure

Applies to: `OpenConnectionSwitcherAction`

The action stores the drawer's state (`isPresented`, `isEnabled`) rather than a
closure, because an environment closure is not comparable.

### 2. The open switcher blocks the agent history drawer

Applies to: `ConnectionSwitcherOpenPreference`

The preference is true while the Connections switcher is open, so the global
agent history drawer does not compete for the same horizontal pans.

### 3. New window is long-press only

Applies to: `WorkspaceConnectionSwitcher.newWindowAction`

Opening a connection in a new window is offered on long-press only. The action
is nil on iPhone, where windows cannot be added.
