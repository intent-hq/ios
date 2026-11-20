# ADR-0907: Transcript copy context menu overlay

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `CopyContextMenuOverlay`, `CopyContextMenuOverlay.OverlayView`, `CopyContextMenuOverlay.Coordinator`, `CopyContextMenuPassthroughMarker`, `View.copyContextMenuPassthrough()`, `UIView.textInputDescendant(containing:with:excluding:)`, `UIView.passthroughMarkerDescendant(containing:with:excluding:)`, `UprightPreviewTransform` (`Intent/Views/Conversation/Transcript/CopyContextMenuOverlay.swift`), `MessageCopyContextMenu` (`Intent/Views/Conversation/Transcript/MessageCopyContextMenu.swift`)
- Related issues: ios#140, ios#344, intent-hq/monorepo#3441

## Context

Transcript rows have a long-press "Copy" menu. Its preview must stay upright
during the lift, open, and dismissal phases. The menu must not break taps,
selection, or scrolling inside the row.

## Decisions

### 1. Use `UIContextMenuInteraction`, not SwiftUI's `.contextMenu`

Applies to: `CopyContextMenuOverlay`

SwiftUI's `.contextMenu { } preview: { }` can only customize the open preview
of a context menu. The lift (highlight) animation that plays while the long
press is recognized always snapshots the source view.
`UIContextMenuInteraction` is the only API with a hook over the lift itself.
Its delegate returns an upright `UITargetedPreview` for the highlight and the
dismissal phases, so no frame of the press-to-menu transition shows the
default snapshot.

### 2. Attach the interaction through a transparent overlay

Applies to: `CopyContextMenuOverlay`

The interaction is attached through a transparent overlay, so the row content
stays in the plain SwiftUI hierarchy. The overlay renders nothing and lays out
at the row's size. Adding or removing the interaction never touches the row's
identity or layout.

Rejected alternative: the previous implementation (`CopyContextMenuHost`,
ios#140) nested the row content inside a `UIHostingController`, so the
interaction's view was an ancestor of the content. That hosting boundary
needed `sizeThatFits` self-sizing. Its deferred invalidation drew a garbled
first frame on conversation load. Gating the host on stream settle also
changed the row subtree's structure and discarded its local state
(intent-hq/monorepo#3441).

### 3. The overlay is inert while disabled

Applies to: `CopyContextMenuOverlay.isEnabled`, `CopyContextMenuOverlay.updateUIView(_:context:)`

`isEnabled` comes from `MessageCopyContextMenu.shouldEnableCopyInteraction`.
While it is false, the interaction is removed and the overlay is invisible to
hit-testing. Removing the interaction can tear down a live menu without its
`willEndFor` completion ever running. So `updateUIView` releases the retained
preview controllers itself, and the retention does not depend on UIKit's
callback ordering.

### 4. Hit-testing is selective

Applies to: `CopyContextMenuOverlay.OverlayView.hitTest(_:with:)`

The overlay is a sibling above the row content, not an ancestor. UIKit
delivers every touch the overlay claims to the overlay's own recognizers and
its ancestors' only. So the overlay claims a touch only when the view that
would otherwise receive it is one of the overlay's own ancestors: the shared
hosting view with plain SwiftUI row content, whose gestures live on that
ancestor and keep working. It passes the touch through when a UIKit-backed
sibling subtree (code-block or tool-call `UIScrollView`s) would claim it. In-row
scrolling keeps working there, at the cost of no copy long-press over those
regions.

1. Re-entrancy guard: the probe re-runs hit-testing with this view disabled.
   Whether UIKit skips a disabled view parent-side or receiver-side is
   undocumented. The `isUserInteractionEnabled` check makes the probe
   terminate by construction.
2. The probe finds the view that the touch would reach without the overlay. It
   runs from the window, not the immediate superview. In production that
   superview is SwiftUI's per-representable wrapper, sized to the overlay with
   the overlay as its only subview, so a probe from there could never see the
   row's real UIKit siblings.
3. The exclusive single-child wrapper chain is disabled with the overlay, so a
   positive hit on a wrapper cannot mask what is beneath. The walk stops at the
   first ancestor with other subviews (a real container).
4. A scroll container can win the probe while a zero-framed wrapper hides a
   button marker beneath it. The touch goes to that marker first.
5. On pass-through the overlay returns the probed view rather than nil, so the
   touch reaches it even when an intermediate wrapper would hit-test
   positively for this region and claim it.
6. A probe that resolves to an ancestor normally means plain SwiftUI row
   content, which the overlay claims. But Textual's text-interaction view
   (selection long-press, link taps) is a UIKit sibling that the recursive
   hit-test can skip when an intermediate SwiftUI wrapper reports a stale or
   zero frame. This was observed in transcript `LazyVStack` rows, where
   hit-testing never reached it even though selection worked in plain note
   views. Its gesture recognizers hang off the view itself, so an ancestor hit
   cannot serve them. The overlay defers to any text-input descendant that
   claims the point directly.

### 5. Descendant searches ignore intermediate bounds

Applies to: `UIView.textInputDescendant(containing:with:excluding:)`,
`UIView.passthroughMarkerDescendant(containing:with:excluding:)`

The depth-first search looks for a visible matching descendant (a
`UITextInput` view, such as Textual's text-interaction view, or a passthrough
marker) that claims the point through its own `point(inside:with:)`. The walk
ignores intermediate views' bounds on purpose. A zero-framed SwiftUI wrapper
between the row container and the target would fail the parent-side
containment check of regular hit-testing and hide a correctly framed target.
`excluding` prunes the caller's own subtree.

### 6. Passthrough markers let row controls keep their gestures

Applies to: `CopyContextMenuPassthroughMarker`, `View.copyContextMenuPassthrough()`

The overlay claims any touch whose probe resolves to plain SwiftUI content. So
taps on an attached image never reached its `Button` or its `.contextMenu`, and
tool rows in text-bearing assistant messages did not expand (ios#344).

The marker is a transparent UIKit view placed behind tappable controls, such
as image thumbnails and tool-call row headers. It is a sibling beneath the
overlay. The probe resolves to the marker, the overlay passes the touch
through, and SwiftUI routes it to the gestures above the marker in its own
tree: the Button's tap (lightbox) and the thumbnail's long-press (image
Save/Copy menu). The cost is no message-copy long-press directly over a
thumbnail; the bubble's text keeps it. The marker has no gestures of its own.

Apply `copyContextMenuPassthrough()` to the tappable content itself, such as a
Button's label, so the Button and any `.contextMenu` on it are ancestors of
the marker. Only touches inside the marker's frame pass through, so it must
cover the whole tap area. `IntentButtonStyle` does this for its pill with
`passesThroughCopyMenu`. `CopyContextMenuPassthroughPolicyTests` requires it
on every Button in a transcript row.

### 7. Preview controllers live until the end animation completes

Applies to: `CopyContextMenuOverlay.Coordinator.liveControllers`,
`CopyContextMenuOverlay.Coordinator.releaseRetainedPreviews()`

Every in-flight preview's hosting controller stays alive while UIKit animates
its retained view. With no `previewProvider`, the highlight preview's view is
also the open menu's preview. The dismissal phase creates a second controller
while the first is still on screen. So all controllers of one interaction are
retained and released together, only after the end animation completes
(`willEndFor`). `releaseRetainedPreviews()` releases them at once when the
interaction is removed while a menu may be open, because `willEndFor`'s
completion is then not guaranteed to run.

### 8. The upright preview needs a window

Applies to: `CopyContextMenuOverlay.Coordinator.uprightPreview(for:)`

The preview is rendered into a fresh hosting controller and anchored at the
overlay's center, with a transform that cancels any flip or rotation the
container inherits. So the lift and dismissal animations stay upright at every
frame. It serves both the highlight and the dismissal phases. With no
`previewProvider`, the open menu displays it too.

The container must be in a window, because `UIPreviewTarget` raises otherwise.
In a `LazyVStack` the row can be detached between menu open and dismissal (fast
scroll, or a row recycled by a transcript update). Returning nil then falls
back to UIKit's default dismissal instead of crashing.

### 9. The corrective transform is a general inverse

Applies to: `UprightPreviewTransform.accumulated(from:)`,
`UprightPreviewTransform.corrective(from:)`

UIKit places a `UITargetedPreview` in its container's coordinate space, so a
container under a flipped ancestor would flip the preview with it. The
transcript is a natural-order ScrollView today and applies no transforms, so
the correction resolves to the identity there. It stays as the general inverse
of the container's accumulated layer transform, upright however flips are
spread across ancestors.

1. `accumulated(from:)` keeps only the linear part of the transform from the
   layer to the root of its layer tree. The translation is stripped because
   the preview target's `center` supplies the position.
2. `corrective(from:)` returns the identity when the transform is degenerate.
   The epsilon (`minimumInvertibleDeterminant`) is loose on purpose. A nearly
   singular transform, such as an ancestor that scales through about 0 during
   an animation, would invert into an enormous correction for a frame, so it
   counts as degenerate too. Realistic inputs are flips with |det| = 1.
