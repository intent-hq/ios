# ADR-0003: Window binding, retargeting, and backend removal

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `IntentApp`, `WindowRetargetRoute`, `SessionWindowRoot`, `BackendWindowRoot`, `RemovedWindowCloseAction`, `RemovedBackendPlaceholderView` (`Intent/App/IntentApp.swift`), `BackendWindowSession` (`Intent/App/BackendWindowSession.swift`)
- Related issues: ios#897

## Context

In window model v2 every window is bound to exactly one backend. The window's
scene value is a `BackendID?`. The window must attach the backend's shared
session (ADR-0002), switch to other backends, return Home, and react when its
backend is removed.

## Decisions

### 1. The scene value is the binding contract

Applies to: `IntentApp.body`, `BackendWindowRoot`

`openWindow(value:)` raises the existing window for a backend or opens a new
one. System restoration reopens the last open windows with their values. A
bound window attaches its backend's shared session through the registry and
releases it when the window closes or rebinds, so the registry tears the
session down at zero windows.

A nil scene value (plain launch, restoration loss) is resolved once to the
last-used backend. On a plain launch `onAppear` sets `backendID` to the
last-used backend, and `bindCurrentBackend` then runs through
`onChange(of: backendID)`. With no backend paired, the window runs a transient
pairing session until a pairing completes and rebinds it through the retarget
hook.

In DEBUG, the connection and settings demos use this process's fresh fixtures,
not an obsolete native scene value or restored Home state.

### 2. Home releases the backend but keeps the scene value

Applies to: `BackendWindowSession`, `BackendWindowSession.sceneTitle`, `BackendWindowSession.restoreSavedMachines(_:isDemo:)`, `BackendWindowRoot.restoresSavedMachines`

`BackendWindowSession` owns one window's attachment independently of its
native scene value. Returning Home keeps that value, so `openWindow` can still
raise the native window, but releases the backend and shows a fresh, unbound
pairing session. The attachment identity survives navigation and connection
loss. The native scene value alone cannot tell a bound window from Home.

The per-scene Home flag (`@SceneStorage("backendWindowShowsSavedMachines")`)
restores an unbound pairing session instead of auto-connecting. Selecting the
native backend reattaches it. `SceneStorage` survives the demo's ephemeral
persistence, so a fresh demo launch ignores the flag. Explicit Home navigation
is honored for the rest of the window's lifetime, including reappearances.

### 3. Rebinding

Applies to: `BackendWindowSession.rebind(to:)`, `prepareToRebind()`, `BackendWindowRoot` (`.id(ObjectIdentifier(session))`)

- `rebind(to:)` is also used for an unchanged scene value: writing the same
  `BackendID` cannot trigger SwiftUI's `onChange` after returning Home.
- `prepareToRebind()` leaves binding to the root when the root must first validate a saved record.
- A rebind must build a fresh `SessionWindowRoot` (a new coordinator over the
  new session), not update the old one in place. The root is keyed by the
  session's `ObjectIdentifier`.

### 4. Scene-owned network lease and title

Applies to: `BackendWindowSession.updateNetworkObservation(for:)`, `refreshSceneTitle()`

The network availability lease is scene-owned, not session-owned. Home,
rebinds, and retries keep the same lease. A temporarily locked or unavailable
Keychain must not erase a known window label: when
`loadConnectionsWithOutcome()` returns no connections, the label is kept. A
successful read with no matching record clears it.

### 5. Retarget policy per platform

Applies to: `WindowRetargetRoute`, `BackendWindowRoot.retarget(to:choosingInPlace:)`

- Where multiple windows are supported, an unbound (pairing) window is
  replaced by the target's own window instead of being rebound. The first
  window bound after pairing then keeps a native scene value that
  `openWindow(value:)` can raise. The pairing window dismisses itself only
  after the replacement scene connects (`dismissWhenReplacementConnects()`,
  a bounded wait).
- On visionOS every backend gets its own window. Picking another machine
  opens or raises that machine's window, and this window keeps its backend.
- iPad and iPhone switch a bound window in place (ios#897). "Open in New
  Window" in a connection's context menu is the explicit iPad multi-window path.
- A window that is not showing a connected machine (Home, pairing, connecting,
  or a connection failure) is choosing what it shows, so it also switches in place.

The Bool passed to the `SessionWindowRoot` retarget hooks is the coordinator's
`choosesBackendInPlace`.

### 6. Selection tokens go only to new coordinators

Applies to: `BackendWindowSession.prepareForSelection(to:route:)`

The explicit selection mark (ADR-0002, decision 6) goes to a new coordinator,
not to an existing window that is only raised or left on the same backend.
For `.openTargetWindow` and `.replaceWindow`, raising an attached window
creates no coordinator to consume the token, so the mark is skipped when the
target already has attachments. Otherwise the selection would leak into later
restoration.

### 7. One coordinator per scene

Applies to: `SessionWindowRoot`

`SessionWindowRoot` owns the window's `AppCoordinator` in `@State`, so windows
that share a session navigate independently (spec "State split"). The
session's restoration claim is consumed lazily on first use, so coordinators
built for discarded view constructions never spend it. Scene phase and
incoming URLs are handled here so each coordinator sees its own scene's lifecycle.

### 8. A removed backend closes or rebinds its window, never leaving zero windows

Applies to: `BackendWindowRoot.isRemoved`, `bindCurrentBackend()`, `closeRemovedWindow()`, `RemovedWindowCloseAction.forWindowCounts(connectedWindowScenes:attachedRemovedBackendWindows:)`, `RemovedBackendPlaceholderView`

When the registry marks the window's backend removed (user delete, log off,
synced tombstone, or on bind a restored window whose saved record no longer
exists), the session is released at once, which drops the connection through
the normal detach path. The window then dismisses itself with
`dismissWindow(value:)`. The app's last window rebinds to the pairing surface
instead. There is never zero windows and never a silently dead surface.

- `bindCurrentBackend()` marks a window restored or retargeted after its
  backend's record was removed, so the shared auto-close path takes over.
- `onChange(of: isRemoved, initial: true)` uses `initial` to cover a mark set
  before the window ever rendered: removal racing a window that is still
  opening or being restored.
- `forWindowCounts`: `connectedWindowScenes` includes the removed window
  itself. `attachedRemovedBackendWindows` counts sibling windows still attached
  to the removed backend; the deciding window has already detached. Only
  windows outside both, the scenes that survive the removal, justify a dismiss.
  Siblings are excluded because they will run the same decision and cannot be
  relied on to survive. Two windows on the removed backend therefore never
  both race into `.dismiss` and end at zero windows: the first to decide
  rebinds to pairing, and the later one counts it as surviving and dismisses.
- If a dismissal cannot be delivered, `RemovedBackendPlaceholderView` stays. It
  names the state and offers a manual Close Window button that applies the
  same decision and works even as the last window.

### 9. App-wide session observers

Applies to: `IntentApp.init()`, `IntentApp.networkAvailability`

Agent alerts are aggregated across every live backend session. Each session
attaches an observer on creation and detaches on last-window teardown.
Transient pairing sessions have no backend to observe. In DEBUG the
connection-loss demos substitute a scripted network monitor.
