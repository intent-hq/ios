# 0095. Backend sessions, windows and pairing

**Status:** Accepted (recorded 2026-11-20 from test comments)

## Context

The app can save several machines (backends) and show them in several windows. `BackendSessionRegistry` shares one session per backend. Each window has its own `BackendWindowSession` and coordinator.

## Decision

1. **Per-window navigation.** Coordinators over one session navigate independently. A sibling window is not affected by navigation in another window.
2. **Restoration.** Last-screen state is stored per backend. Only the first window on a backend restores it; a duplicated window starts at the workspace list. A window on another backend starts at the workspace list.
3. **Removed backends.** Removal is observable and idempotent (`markBackendRemoved(_:)`).
4. **Binding.**
   1. The root calls `rebind(to:)` for an unchanged scene value. `onChange` does not fire when the same machine is selected again.
   2. The window restores its per-scene Home flag before it binds the native `BackendID`. This never attaches, even for a moment.
   3. Control Center makes a scene inactive, not backgrounded; network observation follows `updateNetworkObservation(for:)`.
   4. On foreground, the window reads the machine name from the registry again. A refresh while the app was suspended sends no in-process event.
5. **Pairing.**
   1. Pairing publishes the backend even when the first refresh learns no route.
   2. A new pairing can connect over the transient Home session.
   3. Pairing machine B from one of two windows on machine A rebinds that window. The window that stays on A dials its hijacked shared connection again. Where backends get separate windows, B opens its own window and this window dials its own connection again.
   4. Only an owner that the connection verified is published. The legacy `PersistenceManager.savePairing(server:token:)` shim has no authority.

## Code

- `BackendSessionRegistry`: `markBackendRemoved(_:)`
- `BackendWindowSession`: `rebind(to:)`, `restoreSavedMachines(_:isDemo:)`, `updateNetworkObservation(for:)`
- `PersistenceManager`: `savePairing(server:token:)`
- `BackendSessionRegistryTests`, `BackendWindowSessionTests`, `BackendWindowTitleTests`, `BackendRoutePublicationTests`, `BackendSyncTestSupport`
