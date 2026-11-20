# ADR-1215: Remote read-only controls and placeholders

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `EnvironmentValues.isRemoteReadOnly`, `View.requiresLiveConnection(_:)`, `View.disabledWhileReadOnly()`, `View.onReconnect(_:)` (`Intent/Views/Connection/RemoteReadOnly.swift`), `AvailableWhenReconnectedView`, `View.availableWhenReconnected(isMissing:isCompact:)` (`Intent/Views/Connection/AvailableWhenReconnectedView.swift`)

## Decisions

### 1. `isRemoteReadOnly` is per window

Applies to: `EnvironmentValues.isRemoteReadOnly`

It is true while this window's Mac connection is lost (read-only or stopped).
`RootView` sets it per window; sheets and covers inherit it.

### 2. Controls that change the Mac are disabled and explain themselves

Applies to: `View.requiresLiveConnection(_:)`, `RequiresLiveConnection`

The modifier disables a control that sends a change to the Mac while the
connection is lost, and explains itself on tap. A disabled control ignores
taps, so a clear overlay catches them and shows the hint instead of doing
nothing. It adds to permission checks and never replaces them: pass those
through `.disabled` as before.

### 3. Menus, toolbars, and swipe actions are disabled only

Applies to: `View.disabledWhileReadOnly()`

A tap hint cannot attach to controls inside menus, toolbars, and swipe actions,
so those controls are only disabled.

### 4. Screens reload by themselves on reconnect

Applies to: `View.onReconnect(_:)`

`onReconnect` runs its action when this window's Mac connection comes back, so
screens that failed during a drop reload by themselves.

### 5. Missing content shows "available when reconnected"

Applies to: `AvailableWhenReconnectedView`, `View.availableWhenReconnected(isMissing:isCompact:)`

When the app has no copy of the content and the Mac connection is lost, this
view replaces a loading state or an error. `isMissing` says that the content
was never loaded. The owning screen reloads by itself on reconnect, so there is
nothing to retry here. `isCompact` gives an inline row for embedded sections;
otherwise the view is a full empty state.
