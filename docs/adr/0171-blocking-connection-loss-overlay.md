# ADR-0171: Blocking connection-loss overlay

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConnectionLossLayers` (`Intent/Views/Connection/ConnectionLossLayers.swift`), `ConnectionLossPresenter` (`Intent/Views/Connection/ConnectionLossPresenter.swift`), `ConnectionLossOverlay` (`Intent/Views/Connection/ConnectionLossOverlay.swift`)

## Context

A window has two connection-loss surfaces. The blocking screen shows once
reconnection stops. The read-only banner (ADR-0172) shows while reconnection
keeps trying. `ConnectionLossLayers` mounts both.

## Decisions

### 1. The overlay is only for a final loss

Applies to: `ConnectionLossOverlay`

The overlay shows only when reconnection stopped for good: revoked access, a
different person, or an incompatible host. Ordinary drops use `ReadOnlyBanner`.

### 2. The overlay is a window in the same scene

Applies to: `ConnectionLossPresenter`

A root overlay is below sheets and full-screen covers. A window in the same
scene covers those presentations without dismissing them or losing drafts. The
window level is `.alert + 1`. Visibility is set synchronously, outside
SwiftUI's transition machinery.

### 3. Window attachment survives temporary removal

Applies to: `ConnectionLossPresenter.updateUIView(_:context:)`, `ConnectionLossPresenter.Coordinator.attach(to:)`

An initial update can come before `didMoveToWindow`, so `updateUIView` also
attaches when the anchor already has a window. UIKit and SwiftUI may remove the
anchor from its window for a short time during scene transitions. A missing
window is not a request to dismiss an existing loss or to discard pending
content. The coordinator keeps the source window until a real rebind, recovery,
Home, or `dismantleUIView` tears it down. `dismantleUIView` owns permanent
teardown.

### 4. The Home action does not retain the coordinator

Applies to: `ConnectionLossPresenter.Coordinator.homeAction(_:)`

SwiftUI owns the coordinator while it is mounted. The stored content must not
own it back, even before a window exists, so the action captures it weakly.

### 5. The backdrop is a blurred snapshot of the page

Applies to: `ConnectionLossPresenter.Coordinator.refresh()`, `ConnectionLossPresenter.Coordinator.snapshot(of:)`

Before the overlay window shows, the coordinator freezes the actual page,
including presented sheets, as a snapshot. A material would add its own tint on
top of the design's tint and flatten the frosted detail. One point per pixel is
enough for this diffuse backdrop. The image is transient and kept in memory
only; `hide` releases it on every exit.

### 6. Overlay layout

Applies to: `ConnectionLossOverlay`

Only the backdrop ignores safe areas. The content and the action scroll together
when large text or certificate warnings need more than the available height.
The artwork is balanced around the full window center, not the asymmetric
status-bar and home-indicator safe-area center. The title, body, and action
tracking values were resolved in Figma frame 2989:20669 and stay local to this
overlay.

### 7. The overlay always renders dark

Applies to: `ConnectionLossOverlay.sourceColorScheme`, `ConnectionLossOverlay.body`

The source page can be light even though the overlay always renders dark, so
`sourceColorScheme` carries the source scheme. The overlay overrides the source
environment copied by the presenter, and the window's appearance, so refreshed
warnings and chrome stay dark.
