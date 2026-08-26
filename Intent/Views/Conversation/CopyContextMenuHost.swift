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
/// The row content is hosted in a `UIHostingController` so the interaction's
/// view both receives the long press and anchors the preview;
/// `sizeThatFits` keeps the row self-sizing inside the transcript's
/// LazyVStack, and an `onGeometryChange` revision bump re-queries it when
/// the hosted content resizes itself (e.g. a response group collapsing),
/// which SwiftUI cannot observe across the hosting boundary.
struct CopyContextMenuHost<RowContent: View, Preview: View>: View {
    /// Pasteboard payload of the single "Copy" menu action.
    let text: String
    /// Upright preview shown during the lift, open, and dismissal phases.
    let preview: Preview
    @ViewBuilder let content: () -> RowContent
    /// Bumped whenever the hosted content changes size on its own so the
    /// representable re-runs `sizeThatFits`. The bump is deferred to the
    /// next main-actor turn: the geometry-change action fires while the
    /// nested hosting controller is being laid out from within the outer
    /// view update, and SwiftUI drops re-entrant state writes made during
    /// that pass — the dropped write left the row frozen at a stale height.
    @State private var sizeRevision = 0

    var body: some View {
        CopyContextMenuRepresentable(
            text: text,
            preview: AnyView(preview),
            sizeRevision: sizeRevision,
            rowContent: AnyView(
                content().onGeometryChange(for: CGSize.self) { proxy in
                    proxy.size
                } action: { _ in
                    Task { @MainActor in
                        sizeRevision &+= 1
                    }
                }
            )
        )
    }
}

private struct CopyContextMenuRepresentable: UIViewRepresentable {
    let text: String
    let preview: AnyView
    let sizeRevision: Int
    let rowContent: AnyView

    func makeCoordinator() -> Coordinator {
        Coordinator(text: text, preview: preview)
    }

    // Tradeoff: the hosting controller is used view-only — it is never added
    // as a child view controller (UIViewRepresentable offers no parenting
    // hook), so it misses UIKit containment callbacks (appearance
    // transitions, responder-chain edge cases). With `safeAreaRegions = []`
    // and self-contained row content this works, but keep it in mind if row
    // content ever grows containment-sensitive behavior.
    func makeUIView(context: Context) -> UIView {
        let coordinator = context.coordinator
        coordinator.contentController.rootView = environmentWrapped(rowContent, context: context)
        let view: UIView = coordinator.contentController.view
        view.backgroundColor = .clear
        view.addInteraction(UIContextMenuInteraction(delegate: coordinator))
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = text
        coordinator.preview = preview
        coordinator.contentController.rootView = environmentWrapped(rowContent, context: context)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        _ = sizeRevision
        return context.coordinator.contentController.sizeThatFits(
            in: CGSize(
                width: proposal.width ?? .greatestFiniteMagnitude,
                height: proposal.height ?? .greatestFiniteMagnitude
            )
        )
    }

    /// A nested hosting controller doesn't inherit the SwiftUI environment
    /// from the outer hierarchy, so forward the representable context's
    /// environment wholesale (row descendants read `@Environment` values
    /// injected above the transcript).
    private func environmentWrapped(_ view: AnyView, context: Context) -> AnyView {
        AnyView(view.environment(\.self, context.environment))
    }

    @MainActor
    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        let contentController: UIHostingController<AnyView>
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
            self.contentController = UIHostingController(rootView: AnyView(EmptyView()))
            self.text = text
            self.preview = preview
            super.init()
            contentController.safeAreaRegions = []
            contentController.view.backgroundColor = .clear
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
        /// at the row's center with a transform cancelling whatever
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
