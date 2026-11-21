# ADR-0168: Task status icon and task progress ring match the desktop frontend

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `TaskStatusIconView` (`Intent/Views/Components/TaskStatusIconView.swift`), `TaskProgressRingView` (`Intent/Views/Components/TaskProgressRingView.swift`)

## Context

Both views copy the desktop frontend ("fe") artwork.

## Decisions

### 1. Task status icon per status

Applies to: `TaskStatusIconView`

The icon visually matches the desktop frontend's `TaskStatusIcon.svelte`:

- notStarted: empty gray outline circle; unknown adds a question mark.
- waiting: gray outline circle with a clock glyph. This is a deliberate
  addition; the fe currently renders waiting identically to not_started.
- discussionNeeded: amber filled circle with a question mark.
- blocked: red filled circle with an exclamation mark.
- inProgress: blue outline, right half filled.
- reviewRequired: blue filled circle with an eye.
- complete: green filled circle with a white checkmark.
- cancelled: gray outline circle with a diagonal line. It has no fill in the fe
  (`innerCircleRPercentage` 0).

### 2. Geometry is in the fe's 24×24 viewBox space

Applies to: `TaskStatusIconView.scale`, `TaskStatusIconView.fill`

All geometry is defined in the fe's 24×24 viewBox space and scaled to `size`.
`fill` gives the inner circle color and radius in reference units, or nil for
no fill.

### 3. The in-progress outline has an extra inner ring

Applies to: `TaskStatusIconView.body`

The fe draws an extra inner ring (r=10, width 2) that thickens the in-progress
outline inward.

### 4. The in-progress half fill is pinned to LTR

Applies to: `TaskStatusIconView.fillCircle(color:radius:)`

Only the part right of x = 11.52 (48% of 24) is visible. The fill circle spans
x ∈ [12 − radius, 12 + radius]. The mask is pinned to LTR so the visible half
never flips under RTL; the fe clip is an absolute x=48% rect.

### 5. Palette

Applies to: `TaskStatusIconView.Palette`, `TaskProgressRingView.Palette`

`TaskStatusIconView.Palette` is the shared task-status palette. `amber` doubles
as the warning color for conflict relation chips (fe `text-warning`). Values:
gray #99999966, amber #f59e0b, red #ef4444, skyBlue #00BCFF, blue #3b82f6,
greenStroke #22c55e, greenFill #00BD7D.

The progress ring track is the same muted gray as the status icon outlines
(#99999966). The completed arc is the fe's emerald-500 (#10b981). The
in-progress arc is the app's in-progress blue (#00BCFF).

### 6. Progress ring shape

Applies to: `TaskProgressRingView`

The circular linked-task progress ring matches the fe sidebar's NotesPanel ring:
a muted track, a green arc for the completed fraction, and a blue arc for the
in-progress fraction drawn right after the completed one. Arcs start at 12
o'clock and run clockwise. SwiftUI trims start at 3 o'clock, so the ring is
rotated by `startAngle`. The layout direction is pinned to LTR to keep the arc
geometry stable under RTL mirroring.
