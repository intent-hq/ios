# ADR-0159: Agent avatar tile, colors, and render-server pulse

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `AgentAvatarView` (`Intent/Views/Agents/AgentAvatarView.swift`), `AgentAvatarPulse` (`Intent/Views/Agents/AgentAvatarPulse.swift`)

## Context

`AgentAvatarView` draws a rounded-tile agent avatar with brand artwork and
state-aware surfaces. A running agent shows a pulsing ring.

## Decisions

### 1. Workspace rows use the iOS assets; other surfaces keep the desktop geometry

Applies to: `AgentAvatarView`, `AgentAvatarView.artSize`, `AgentAvatarView.cornerRadius`

With `workspaceStyle`, the tile uses the iOS image assets and the
`WorkspaceDetailStyle` ratios. Other surfaces use the desktop geometry ratios
from `avatar-size.ts` "standard": surface 20, art 16, clear space 2, corner
radius 6.

### 2. `icon` is the specialist icon metadata

Applies to: `AgentAvatarView.icon`

`icon` carries the specialist icon metadata defined in PROTOCOL §5.11.

### 3. Surface and glyph colors follow the desktop tokens

Applies to: `AgentAvatarView.surfaceColor`, `AgentAvatarView.glyphColor`

The non-workspace surface per state follows the desktop
`--agent-avatar-surface-*` tokens. Idle is the neutral hsl(145 14% 92%) in light
mode and hsl(145 12% 78%) in dark mode.

The desktop glyph color is near-black (#080808) in both schemes: the tile stays
light, so the glyph stays dark. The completed tile darkens in dark mode, so it
carries its own foreground token (`glyphCompleted`).

### 4. Glyph paths are drawn in a 16×16 art space

Applies to: `artTransform(for:)`

The glyph art space is 16×16 (`Constants.AgentAvatar.referenceArtSize`).
`artTransform(for:)` maps it onto the shape's rect.

### 5. The pulse animates only the layer's stroke color in the render server

Applies to: `AgentAvatarView.body`, `AgentAvatarPulse`

The pulse is a `CAKeyframeAnimation` on a `CAShapeLayer` stroke color. It needs
no per-frame SwiftUI updates and does not animate SwiftUI geometry. An earlier
implicit `repeatForever` SwiftUI animation made rings drift between rows when a
list reordered.

### 6. Pulse timing matches the earlier PhaseAnimator

Applies to: `AgentAvatarPulse.PulseView.endpointHoldDuration`

Each endpoint is held for 50 ms. That is how long `PhaseAnimator` held each
endpoint on the 60 Hz reference recording.

### 7. The ring reuses SwiftUI's continuous path

Applies to: `AgentAvatarPulse.PulseView.layoutSubviews()`

The ring path comes from SwiftUI's continuous `RoundedRectangle` path, including
its centered stroke, so it matches the SwiftUI tile.

### 8. The pulse is reinstalled on activation, never restarted on view updates

Applies to: `AgentAvatarPulse.PulseView.updatePulse()`

UIKit delivers `didBecomeActiveNotification` on the main thread.
`updatePulse()` reinstalls the animation when backgrounding removed it. It does
not restart a pulse that is already running with the same colors on view
updates.
