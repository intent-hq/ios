import SwiftUI
import UIKit

/// UIKit-backed replacement for SwiftUI's `.contextMenu { } preview: { }` on
/// transcript rows. SwiftUI can only customize the OPEN preview of a context
/// menu — the lift/highlight animation played while the long press is being
/// recognized always snapshots the source view, and that snapshot mishandles
/// the flipped transcript hierarchy's rotation/scale transforms (see
/// `MessageCopyContextMenu`). `UIContextMenuInteraction` is the only API with
/// a hook over the lift itself: the delegate returns an upright
/// `UITargetedPreview` for the highlight AND dismissal phases, so no frame of
/// the press → menu transition ever shows the default (flipped) snapshot.
///
/// The interaction is attached via this transparent overlay so the row
/// content stays in the plain SwiftUI hierarchy. The previous implementation
/// (`CopyContextMenuHost`, ios#140) instead nested the row content inside a
/// `UIHostingController` so the interaction's view was an ancestor of the
/// content — but that hosting boundary required `sizeThatFits` self-sizing
/// whose deferred invalidation drew a garbled first frame on conversation
/// load, and gating the host on stream settle structurally flipped the row
/// subtree, discarding its local state (intent-hq/monorepo#3441). The
/// overlay renders nothing and lays out at the row's size, so removing or
/// adding the interaction never touches the row's identity or layout.
struct CopyContextMenuOverlay: UIViewRepresentable {
    /// Pasteboard payload of the single "Copy" menu action.
    let text: String
    /// Whether the interaction is attached (see
    /// `MessageCopyContextMenu.shouldEnableCopyInteraction`); while false the
    /// overlay is inert and invisible to hit-testing.
    let isEnabled: Bool
    /// Upright preview shown during the lift, open, and dismissal phases.
    let preview: AnyView

    func makeCoordinator() -> Coordinator {
        Coordinator(text: text, preview: preview)
    }

    func makeUIView(context _: Context) -> OverlayView {
        let view = OverlayView()
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: OverlayView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = text
        coordinator.preview = preview
        uiView.setInteractionEnabled(isEnabled, delegate: coordinator)
        if !isEnabled {
            // Removing the interaction can tear a live menu down without
            // its `willEndFor` completion ever running; release the
            // retained preview controllers here so the retention story
            // doesn't depend on UIKit's callback ordering.
            coordinator.releaseRetainedPreviews()
        }
    }

    /// Transparent view carrying the `UIContextMenuInteraction`. Unlike the
    /// old host it is a sibling ABOVE the row content, not an ancestor, so
    /// UIKit would deliver every touch it claims to its own recognizers and
    /// its ancestors' only. Hit-testing is therefore selective: the overlay
    /// claims a touch only when the view that would receive it otherwise is
    /// one of the overlay's own ancestors (the shared hosting view — plain
    /// SwiftUI row content, whose gestures live on that ancestor and keep
    /// working), and passes through when a UIKit-backed sibling subtree
    /// (code-block/tool-call `UIScrollView`s) would claim it, so in-row
    /// scrolling keeps working there at the cost of no copy long-press over
    /// those sub-regions.
    final class OverlayView: UIView {
        private var interaction: UIContextMenuInteraction?

        func setInteractionEnabled(_ enabled: Bool, delegate: UIContextMenuInteractionDelegate) {
            if enabled {
                guard interaction == nil else { return }
                let interaction = UIContextMenuInteraction(delegate: delegate)
                addInteraction(interaction)
                self.interaction = interaction
            } else if let interaction {
                removeInteraction(interaction)
                self.interaction = nil
            }
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            // Re-entrancy guard: the probe below re-runs hit-testing with
            // this view disabled, and whether UIKit's disabled-view skip
            // happens parent-side or receiver-side is undocumented — this
            // check makes the probe terminate by construction.
            guard isUserInteractionEnabled else { return nil }
            guard interaction != nil, self.point(inside: point, with: event) else { return nil }
            guard let window else { return self }

            // Probe: find the view the touch would reach if this overlay
            // weren't there. The probe runs from the window, not the
            // immediate superview: in production that superview is SwiftUI's
            // per-representable wrapper, sized to the overlay with the
            // overlay as its only subview, so a probe from there could never
            // see the row's real UIKit siblings. The exclusive single-child
            // wrapper chain is disabled alongside the overlay so a positive
            // hit on a wrapper can't mask what's beneath; the walk stops at
            // the first ancestor with other subviews (a real container).
            var excluded: [UIView] = [self]
            var ancestor = superview
            while let wrapper = ancestor, wrapper !== window, wrapper.subviews.count == 1 {
                excluded.append(wrapper)
                ancestor = wrapper.superview
            }
            let toRestore = excluded.filter(\.isUserInteractionEnabled)
            for view in toRestore { view.isUserInteractionEnabled = false }
            defer { for view in toRestore { view.isUserInteractionEnabled = true } }

            let below = window.hitTest(convert(point, to: window), with: event)
            // A scroll container can win the probe while a zero-framed wrapper
            // hides a button marker beneath it. Deliver to that control first.
            if let below,
                let marker = below.passthroughMarkerDescendant(
                    containing: convert(point, to: below),
                    with: event,
                    excluding: self
                ) {
                return marker
            }
            // Pass-through: return the probed view rather than nil, so the
            // touch reaches it even when an intermediate wrapper would
            // otherwise hit-test positively for this region and claim it.
            if let below, !isDescendant(of: below) { return below }
            // The probe resolving to an ancestor normally means plain
            // SwiftUI row content, which this overlay claims. But Textual's
            // text-interaction view (selection long-press, link taps) is a
            // UIKit sibling that can be skipped by the recursive hit-test
            // when an intermediate SwiftUI wrapper reports a stale/zero
            // frame (observed in the flipped transcript's LazyVStack rows,
            // where hit-testing never reached it even though selection
            // worked in plain note views). Its gesture recognizers hang off
            // the view itself, so an ancestor hit can't serve them — defer
            // to any text-input descendant that claims the point directly.
            if let below, isDescendant(of: below),
                let textInput = below.textInputDescendant(
                    containing: convert(point, to: below),
                    with: event,
                    excluding: self
                ) {
                return textInput
            }
            return self
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var text: String
        var preview: AnyView
        /// Keeps every in-flight preview's hosting controller alive while
        /// UIKit animates its (retained) view. With no `previewProvider`,
        /// the highlight preview's view IS the open menu's preview, and the
        /// dismissal phase creates a second controller while the first is
        /// still on screen — so all controllers created during one
        /// interaction are retained and released together only after the
        /// interaction's end animation completes (`willEndFor`).
        private var liveControllers: [UIHostingController<AnyView>] = []

        init(text: String, preview: AnyView) {
            self.text = text
            self.preview = preview
        }

        func contextMenuInteraction(
            _: UIContextMenuInteraction,
            configurationForMenuAtLocation _: CGPoint
        ) -> UIContextMenuConfiguration? {
            let text = text
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                UIMenu(children: [
                    UIAction(title: "Copy", image: UIImage(resource: .copy).withRenderingMode(.alwaysTemplate)) { _ in
                        HapticManager.impact(.light)
                        UIPasteboard.general.string = text
                    }
                ])
            }
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForHighlightingMenuWithConfiguration _: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            uprightPreview(for: interaction)
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForDismissingMenuWithConfiguration _: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            uprightPreview(for: interaction)
        }

        func contextMenuInteraction(
            _: UIContextMenuInteraction,
            willEndFor _: UIContextMenuConfiguration,
            animator: UIContextMenuInteractionAnimating?
        ) {
            if let animator {
                animator.addCompletion { [weak self] in
                    self?.liveControllers.removeAll()
                }
            } else {
                liveControllers.removeAll()
            }
        }

        /// Releases every retained preview controller immediately. Called
        /// when the interaction is removed while a menu may still be open,
        /// where `willEndFor`'s completion is not guaranteed to run.
        func releaseRetainedPreviews() {
            liveControllers.removeAll()
        }

        /// Renders `preview` into a fresh hosting controller and anchors it
        /// at the overlay's center with a transform cancelling whatever
        /// flip/rotation the container inherits from the transcript
        /// hierarchy, so the lift and dismissal animations stay upright at
        /// every frame. Used for both the highlight and dismissal phases;
        /// with no `previewProvider`, the open menu displays it too.
        /// Requires the container to be in a window: `UIPreviewTarget`
        /// raises otherwise, and in a LazyVStack the row can be detached
        /// between menu-open and dismissal (fast scroll, row recycled by a
        /// transcript update) — returning nil falls back to UIKit's default
        /// dismissal instead of crashing.
        private func uprightPreview(for interaction: UIContextMenuInteraction) -> UITargetedPreview? {
            guard let container = interaction.view, container.window != nil else { return nil }
            let controller = UIHostingController(rootView: preview)
            controller.safeAreaRegions = []
            controller.view.backgroundColor = .clear
            let size = controller.sizeThatFits(
                in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            )
            controller.view.frame = CGRect(origin: .zero, size: size)
            liveControllers.append(controller)

            let parameters = UIPreviewParameters()
            parameters.backgroundColor = .clear
            let target = UIPreviewTarget(
                container: container,
                center: CGPoint(x: container.bounds.midX, y: container.bounds.midY),
                transform: UprightPreviewTransform.corrective(from: container.layer)
            )
            return UITargetedPreview(view: controller.view, parameters: parameters, target: target)
        }
    }
}

/// Transparent UIKit view placed behind tappable controls (image thumbnails,
/// tool-call row headers) inside a `MessageCopyContextMenu` row. The copy
/// overlay claims any touch whose probe resolves to plain SwiftUI content (an
/// ancestor hosting view), which is why taps on an attached image never
/// reached its `Button` or its `.contextMenu`, and why tool rows in
/// text-bearing assistant messages did not expand (ios#344). A UIKit view
/// beneath the overlay is a sibling instead: the
/// probe resolves to the marker, the overlay passes the touch through, and
/// SwiftUI routes it to the gestures above the marker in its own tree — the
/// Button's tap (lightbox) and the thumbnail's long-press (image Save/Copy
/// menu). The cost is no message-copy long-press directly over a thumbnail;
/// the bubble's text keeps it. The marker carries no gestures of its own.
struct CopyContextMenuPassthroughMarker: UIViewRepresentable {
    final class MarkerView: UIView {}

    func makeUIView(context _: Context) -> MarkerView {
        let view = MarkerView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        return view
    }

    func updateUIView(_: MarkerView, context _: Context) {}
}

extension View {
    /// Lets taps and long-presses on this view reach its own SwiftUI
    /// gestures through an enclosing `MessageCopyContextMenu` overlay (see
    /// `CopyContextMenuPassthroughMarker`). Apply to the tappable content
    /// itself (e.g. a Button's label) so the Button and any `.contextMenu`
    /// on it are ancestors of the marker. Only touches inside the marker's
    /// frame pass through, so cover the whole tap area; `IntentButtonStyle`
    /// does this for its pill with `passesThroughCopyMenu`.
    /// CopyContextMenuPassthroughPolicyTests requires it on every Button in a
    /// transcript row.
    func copyContextMenuPassthrough() -> some View {
        background { CopyContextMenuPassthroughMarker() }
    }
}

extension UIView {
    /// Depth-first search for a visible `UITextInput`-conforming descendant
    /// (Textual's text-interaction view in transcript rows) that claims
    /// `point` via its own `point(inside:with:)`. The walk deliberately
    /// ignores intermediate views' bounds: a zero-framed SwiftUI wrapper
    /// between the row container and the interaction view would fail the
    /// parent-side containment check that regular hit-testing performs,
    /// hiding a correctly-framed interaction view beneath it. `excluding`
    /// prunes the caller's own subtree.
    func textInputDescendant(
        containing point: CGPoint,
        with event: UIEvent?,
        excluding excluded: UIView
    ) -> UIView? {
        passthroughDescendant(containing: point, with: event, excluding: excluded) { view in
            view is UITextInput
        }
    }

    /// Same walk as `textInputDescendant`, matching a
    /// `CopyContextMenuPassthroughMarker` view (tappable image thumbnails).
    func passthroughMarkerDescendant(
        containing point: CGPoint,
        with event: UIEvent?,
        excluding excluded: UIView
    ) -> UIView? {
        passthroughDescendant(containing: point, with: event, excluding: excluded) { view in
            view is CopyContextMenuPassthroughMarker.MarkerView
        }
    }

    private func passthroughDescendant(
        containing point: CGPoint,
        with event: UIEvent?,
        excluding excluded: UIView,
        where matches: (UIView) -> Bool
    ) -> UIView? {
        for subview in subviews.reversed() {
            guard
                subview !== excluded,
                subview.isUserInteractionEnabled,
                !subview.isHidden,
                subview.alpha >= Constants.Conversation.CopyContextMenu.minimumInteractiveAlpha
            else { continue }

            let localPoint = convert(point, to: subview)
            if matches(subview), subview.point(inside: localPoint, with: event) {
                return subview
            }
            if let match = subview.passthroughDescendant(
                containing: localPoint,
                with: event,
                excluding: excluded,
                where: matches
            ) {
                return match
            }
        }
        return nil
    }
}

/// Corrective transforms for targeted previews anchored inside transformed
/// (flipped) hierarchies. UIKit places a `UITargetedPreview` in its
/// container's coordinate space, so a container sitting under a flipped
/// ancestor would flip the preview with it. The transcript is a natural-order
/// ScrollView today and applies no transforms, so this resolves to the
/// identity there; it stays as the general inverse of the container's
/// accumulated layer transform, upright regardless of how any flips are
/// distributed across ancestors.
enum UprightPreviewTransform {
    /// Linear part (translation stripped — the preview target's `center`
    /// supplies the position) of the accumulated transform from `layer` out
    /// to the root of its layer tree.
    static func accumulated(from layer: CALayer) -> CGAffineTransform {
        var transform = CGAffineTransform.identity
        var current: CALayer? = layer
        while let layer = current {
            transform = transform.concatenating(layer.affineTransform())
            current = layer.superlayer
        }
        transform.tx = 0
        transform.ty = 0
        return transform
    }

    /// Inverse of `accumulated(from:)`, or the identity when that transform
    /// is degenerate. The epsilon is deliberately loose: a nearly-singular
    /// transform (e.g. an ancestor mid-animation scaling through ~0) would
    /// invert into an enormous corrective transform for a frame, so it is
    /// treated as degenerate too. Realistic inputs are flips with |det| = 1.
    static func corrective(from layer: CALayer) -> CGAffineTransform {
        let accumulated = accumulated(from: layer)
        let determinant = accumulated.a * accumulated.d - accumulated.b * accumulated.c
        guard abs(determinant) > Constants.Conversation.CopyContextMenu.minimumInvertibleDeterminant else {
            return .identity
        }
        return accumulated.inverted()
    }
}
