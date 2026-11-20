# 0087. visionOS gaze highlights and hit targets

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

visionOS targets controls by eye and hand. The HIG asks for larger targets, hover feedback on every interactive element, modest depth and no continuous animation. The app's custom button styles draw no system highlight. visionOS is a destination of the single `Intent` target, and every visionOS branch must keep iOS behaviour unchanged.

## Decision

1. **No-ops elsewhere.** Every gaze helper is a no-op off visionOS, so the iOS layout and default button styles stay unchanged. `WorkspaceControlGazeTests` checks this.
2. **Targets.**
   1. Custom row buttons get at least 60 pt height, so stacked rows keep their centers at least 60 pt apart and targets stay above the 44 pt minimum (`visionListRowHitTarget()`).
   2. Composer controls are 60 pt (`controlTarget`); other platforms keep 44 pt. The empty composer field is exactly the control height.
3. **One highlight per control.**
   1. `IntentContentButtonStyle` adds the gaze highlight that system styles would draw. The label shapes it with `visionHoverShape(_:)`, applied as the label's last modifier.
   2. A row or card that draws its own highlight sets `visionContainerDrawsHover`, so the button style does not stack a second one. `visionCardRowButton(cornerRadius:)` drops the bordered capsule and gives the highlight the card's rounded shape.
   3. Workspace controls apply `visionWorkspaceControlHover(cornerRadius:isEnabled:)` inside the label, after its frame, so each action has one shaped gaze target. Segments get extra spacing on visionOS only (`visionSegmentSpacing`).
   4. A disclosure chevron highlights alone while its enclosing `visionHoverGroup()` is looked at (`visionGroupedHoverHint(padding:)`); negative padding keeps the layout unchanged.
4. **Depth and motion.** Rows that need input get a single-step z-lift, scale and brighter status chip (`attentionCueZOffset`). No continuous animation.
5. **Window corners.** The bottom search field sits in a window corner. visionOS fixes the window corner radius, so the field inset keeps its corners concentric with the window (`windowCornerInset`).
6. **Destructive actions.** Archive and delete use a deliberate confirmation sheet on visionOS (`confirmationSheetWidth`).

## Consequences

- A new custom-styled control on visionOS needs a gaze helper, or it shows no hover feedback.
- `WorkspaceActionMenuDepthTests` reads `attentionCueZOffset` from source, so action cards stay in front of raised rows.

## Code

- `IntentContentButtonStyle`, `EnvironmentValues.visionContainerDrawsHover`
- `View`: `visionButtonHover(isEnabled:)`, `visionHoverShape(_:)`, `visionGroupedHoverHint(padding:)`, `visionHoverGroup()`, `visionContainerDrawsHover(_:)`, `visionWorkspaceControlHover(cornerRadius:isEnabled:)`, `visionListRowHitTarget()`, `visionCardRowButton(cornerRadius:)`
- `Constants.Accessibility`: `visionListRowMinimumHeight`, `visionChevronHoverPadding`; `Constants.WorkspaceSearch`: `visionSegmentSpacing`, `windowCornerInset`
- `Constants.Conversation.Composer`: `controlTarget`, `minimumTextViewHeight`
- `Constants.WorkspaceRow`: `attentionCueZOffset`; `Constants.WorkspaceDetail`: `confirmationSheetWidth`
