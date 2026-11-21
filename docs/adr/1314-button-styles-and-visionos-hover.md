# ADR-1314: Button styles and visionOS gaze targets

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `IntentContentButtonStyle`, `IntentButtonStyle` (`Intent/DesignSystem/IntentButtonStyle.swift`),
  visionOS hover helpers and `Constants.Accessibility.visionListRowMinimumHeight`
  (`Intent/DesignSystem/VisionHitTarget.swift`)

## Context

Custom-styled buttons do not get the system's visionOS gaze highlight or hit
target sizes. These helpers add them on visionOS and leave iOS unchanged; every
gaze helper is a no-op off visionOS, which `WorkspaceControlGazeTests` checks. A
new custom-styled control on visionOS needs a gaze helper, or it shows no hover
feedback.

## Decisions

### 1. Content button style adds the visionOS highlight

Applies to: `IntentContentButtonStyle`

`IntentContentButtonStyle` is for controls whose labels own their layout and
enabled/disabled colors. On visionOS it adds the gaze highlight the system
styles would draw; labels shape it with `visionHoverShape(_:)`.

### 2. visionOS row and target sizes

Applies to: `Constants.Accessibility.visionListRowMinimumHeight`,
`View.visionListRowHitTarget()`, `View.visionCardRowButton(cornerRadius:)`

visionOS list rows are 60 pt tall, so adjacent row centers stay at least 60 pt
apart while comfortably exceeding the 44 pt minimum target.
`visionListRowHitTarget` applies eyes-and-hands ergonomics to custom-styled row
buttons: it grows the hit region to a 60 pt minimum height, makes the whole area
tappable, and adds hover feedback. `visionCardRowButton` is for buttons whose
label already draws its own rounded card: it drops the automatic bordered
capsule (`.plain` style) and gives the hover highlight the card's
rounded-rectangle shape, keeping the 60 pt minimum row height. Both are no-ops
on iOS, so the existing layout and the default button style are untouched.

### 3. Hover helpers

Applies to: `View.visionButtonHover(isEnabled:)`, `View.visionHoverShape(_:)`,
`View.visionGroupedHoverHint(padding:)`, `View.visionWorkspaceControlHover(cornerRadius:isEnabled:)`,
`EnvironmentValues.visionContainerDrawsHover`, `Constants.WorkspaceSearch.visionSegmentSpacing`

- `visionButtonHover` adds the gaze highlight for a custom-styled button (HIG:
  every interactive element shows hover feedback). No-op elsewhere.
- `visionHoverShape` sets the visible shape the highlight follows. Apply it as
  the label's last modifier so the button style's highlight picks it up.
- `visionGroupedHoverHint` highlights only a small view (a disclosure chevron)
  while its enclosing `visionHoverGroup()` is looked at. The negative padding
  keeps layout unchanged.
- `visionWorkspaceControlHover` is applied inside each workspace control's
  label, after its frame, so the custom button style keeps a single, shaped gaze
  target per action.
- `visionContainerDrawsHover` is true below a row or label that draws the
  highlight itself, so `IntentContentButtonStyle` does not stack a second one.
- `visionSegmentSpacing` leaves room between the individual gaze highlights
  without changing iOS.

### 4. Transcript-row buttons pass through the copy overlay

Applies to: `IntentButtonStyle.passesThroughCopyMenu`

In a transcript row, every `IntentButtonStyle` button sets
`passesThroughCopyMenu`, which puts a rectangular passthrough marker behind the
whole pill, so taps on its padding reach the button inside the row's copy
overlay (ADR-0907). Taps in the corners outside the rounded pill reach neither
the button nor Copy. `CopyContextMenuPassthroughPolicyTests` enforces this.
