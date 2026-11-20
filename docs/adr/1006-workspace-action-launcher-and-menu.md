# ADR-1006: The Intent menu launcher, its overlay and its visionOS depth

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspaceActionLauncher`, `WorkspaceCompactActionLauncher`, `WorkspaceActionLauncherToolbar`, `WorkspaceActionMenuInputTop`, `WorkspaceVerticalBarKey` (`Intent/Views/Workspaces/WorkspaceActionLauncher.swift`), `WorkspaceActionMenuDepth`, `View.homeActionTileSurface(cornerRadius:fill:)` (`Intent/Views/Workspaces/WorkspaceActionMenuDepth.swift`), `HomeActionTiles` (`Intent/Views/Workspaces/HomeActionTiles.swift`)

## Context

The Intent menu is a launcher button that opens a set of action cards
(`HomeActionTiles`) over the current navigation content. On iPhones with a
system vertical bar, the launcher lives in that bar.

## Decisions

### 1. The menu floats over content without resetting its scroll position

Applies to: `WorkspaceActionLauncher`

The actions float above the navigation content as an overlay, so opening the
menu does not reset the content's scroll position.

### 2. The home-menu fade uses exact 8-bit palette channels

Applies to: `WorkspaceActionLauncher.Layout.shade`

The shade uses exact 8-bit palette channels
(`Constants.DesignPalette.homeMenuFade`) to preserve the shared light and dark
home-menu fade from the IOS Working design file.

### 3. Without a vertical bar, the original modifier chain stays

Applies to: `WorkspaceActionLauncher.floatingMenu(content:)`

`floatingMenu` keeps the original modifier chain and ordering on devices
without a vertical bar.

### 4. The open menu affects the content below it

Applies to: `WorkspaceActionLauncher.floatingMenu(content:)`

`workspaceActionMenuOpen` is set so raised attention rows hide while the menu
is open (ADR-1007).

`accessibilityHidden(isOpen, isEnabled: isEnabled)`: enabled launchers need
explicit visibility for drawer hit testing while closed. Disabled launchers
must preserve the hidden states of retained iPad panes.

The overlay's measured extent (`overlayBottom`) comes from a clear view, so it
stays independent of the padded controls.

`coversConversationComposers(while: isOpen)` is temporary coverage: the
window's floating chat composer hides while the menu is open and keeps its
draft and imports.

### 5. The close control stays inside the modal boundary

Applies to: `WorkspaceActionLauncher.actionControls`

With a vertical bar, the close control renders inside the overlay, so it stays
inside the modal overlay's accessibility boundary.

### 6. Pushed compact Duo screens get their own launcher

Applies to: `WorkspaceCompactActionLauncher`

Pushed compact Duo screens need a launcher after the Workspaces list leaves
the screen.

### 7. Toolbar and overlay ownership

Applies to: `WorkspaceActionLauncherToolbar`

The navigation content owns the toolbar. Its outer launcher still owns the
menu overlay. The modifier itself is gated by
`canImport(SwiftUI, _version: 8.0.85)`, because older SDKs cannot build an
empty toolbar closure.

### 8. The input's top edge shares the overlay's coordinate space

Applies to: `WorkspaceActionMenuInputTop`

The preference carries the active input's top edge in the same global
coordinate space as the launcher overlay.

### 9. The vertical bar edge is a read-only system trait

Applies to: `WorkspaceVerticalBarKey.write(to:value:)`

The key observes a system-owned trait. The app must not override its
placement, so `write` does nothing.

### 10. Tile carousel sizing for large text

Applies to: `HomeActionTiles.carousel`, `HomeActionTiles.carouselTileWidth`

Large text can make cards taller than a short landscape window. The carousel
viewport is capped like the wrapped grid and scrolls vertically when needed.
Accessibility text sizes get one card per viewport so titles wrap at word
boundaries.

### 11. visionOS depth and surface of the action cards

Applies to: `WorkspaceActionMenuDepth.tileZOffset`, `WorkspaceActionMenuDepth.usesGlass(reduceTransparency:)`, `View.homeActionTileSurface(cornerRadius:fill:)`

`tileZOffset` (24) is how far the open menu's cards sit in front of the window
plane: clearly ahead of a raised attention row
(`Constants.WorkspaceRow.attentionCueZOffset`), yet restrained.

On visionOS the card surface is native glass with gaze highlighting. Reduce
Transparency replaces the see-through glass with an opaque card. iPhone and
iPad keep the unchanged solid control surface.
