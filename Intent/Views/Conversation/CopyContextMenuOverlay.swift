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

    func makeUIView(context: Context) -> OverlayView {
        let view = OverlayView()
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: OverlayView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = text
        coordinator.preview = preview
        uiView.setInteractionEnabled(isEnabled, delegate: coordinator)
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
            guard interaction != nil, self.point(inside: point, with: event) else { return nil }
            guard let superview else { return self }
            // Re-run the superview's hit-test with this overlay excluded to
            // find the view the touch would reach if the overlay weren't
            // there (standard pass-through probe; the flag flip is invisible
            // outside this call).
            isUserInteractionEnabled = false
            defer { isUserInteractionEnabled = true }
            let below = superview.hitTest(convert(point, to: superview), with: event)
            if let below, !isDescendant(of: below) { return nil }
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
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            let text = text
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                UIMenu(children: [
                    UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                        HapticManager.impact(.light)
                        UIPasteboard.general.string = text
                    }
                ])
            }
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            uprightPreview(for: interaction)
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            uprightPreview(for: interaction)
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            willEndFor configuration: UIContextMenuConfiguration,
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

/// Corrective transforms for targeted previews anchored inside transformed
/// (flipped) hierarchies. UIKit places a `UITargetedPreview` in its
/// container's coordinate space, so a container sitting under the
/// transcript's FlippedUpsideDown transforms would flip the preview with it.
/// The corrective transform is the inverse of the container's accumulated
/// layer transform: an upright result regardless of how the flips are
/// distributed across ancestors, and the identity when they cancel out.
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
        guard abs(determinant) > 1e-6 else { return .identity }
        return accumulated.inverted()
    }
}
