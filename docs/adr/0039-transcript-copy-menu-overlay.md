# 0039. Transcript copy menu overlay and hit-testing

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

A long press on a transcript row opens a Copy menu. SwiftUI's `.contextMenu { } preview: { }` customizes only the open preview; the lift animation always snapshots the source view. An earlier host (`CopyContextMenuHost`, ios#140) nested the row inside a `UIHostingController`. Its self-sizing drew a garbled first frame on load, and gating it on stream settle rebuilt the row subtree and lost its local state (intent-hq/monorepo#3441). Rows also hold their own controls: links, image thumbnails, tool-row headers, and scrollable code blocks.

## Decision

1. **A sibling overlay.** `CopyContextMenuOverlay` attaches a `UIContextMenuInteraction` to a transparent view above the row, not around it. The row content stays in the plain SwiftUI hierarchy. The overlay draws nothing and lays out at the row's size, so adding or removing the interaction never changes the row's identity or layout. `MessageCopyContextMenu.shouldEnableCopyInteraction(text:isStreaming:)` decides when it is attached; while off, the overlay is inert to hit-testing.
2. **Upright previews.** The delegate returns a `UITargetedPreview` for the highlight and dismissal phases, so no frame shows the default snapshot. `uprightPreview(for:)` returns nil when the container is not in a window (a row recycled between open and dismissal), because `UIPreviewTarget` raises otherwise; UIKit then uses its default dismissal.
3. **Preview controller lifetime.** All hosting controllers made during one interaction are kept until its end animation completes (`willEndFor`), because the dismissal phase makes a second controller while the first is still on screen. Removing the interaction releases them at once (`releaseRetainedPreviews()`), because UIKit may never call the completion then.
4. **Selective hit-testing (`OverlayView.hitTest(_:with:)`).** A sibling overlay would take every touch it claims away from the row. So:
   1. The overlay probes, from the window, which view the touch would reach without it. It disables itself and its single-child wrapper chain during the probe, so a wrapper cannot mask what is beneath. A disabled overlay returns nil, so the probe ends by construction.
   2. If the probe reaches a UIKit sibling subtree (a code-block or tool-call `UIScrollView`), the overlay returns that view. In-row scrolling works there; the copy long-press does not.
   3. If the probe reaches an ancestor (plain SwiftUI content), the overlay claims the touch, except when a visible `UITextInput` descendant (Textual's selection and link view) or a passthrough marker claims the point. Those are found by a depth-first walk that ignores intermediate bounds, because a zero-framed SwiftUI wrapper would hide them from normal hit-testing.
   4. A scroll container can win the probe while a zero-framed wrapper hides a button marker under it; the marker wins.
5. **Passthrough markers.** `CopyContextMenuPassthroughMarker` is a transparent UIKit view behind a tappable control. The probe resolves to the marker, the overlay passes the touch, and SwiftUI routes it to the control's own tap and context menu (ios#344). Apply `copyContextMenuPassthrough()` to the control's label and cover its whole tap area; `IntentButtonStyle(passesThroughCopyMenu: true)` does this for its pill. `CopyContextMenuPassthroughPolicyTests` requires it on every `Button` in a transcript row. The cost is no message-copy long-press directly over the control.

## Consequences

- A new tappable control in a transcript row needs a passthrough marker, or the overlay swallows its taps.

## Code

- `CopyContextMenuOverlay`: `OverlayView.hitTest(_:with:)`, `Coordinator.uprightPreview(for:)`, `Coordinator.releaseRetainedPreviews()`
- `CopyContextMenuPassthroughMarker`, `copyContextMenuPassthrough()`, `textInputDescendant(…)`, `passthroughMarkerDescendant(…)`
- `MessageCopyContextMenu`: `shouldEnableCopyInteraction(text:isStreaming:)`
- `UprightPreviewTransform`
