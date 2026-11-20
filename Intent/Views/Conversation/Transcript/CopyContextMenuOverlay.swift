import SwiftUI
import UIKit

struct CopyContextMenuOverlay: UIViewRepresentable {
    let text: String
    let isEnabled: Bool
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
            coordinator.releaseRetainedPreviews()
        }
    }

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
            guard isUserInteractionEnabled else { return nil }
            guard interaction != nil, self.point(inside: point, with: event) else { return nil }
            guard let window else { return self }

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
            if let below,
                let marker = below.passthroughMarkerDescendant(
                    containing: convert(point, to: below),
                    with: event,
                    excluding: self
                ) {
                return marker
            }
            if let below, !isDescendant(of: below) { return below }
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

        func releaseRetainedPreviews() {
            liveControllers.removeAll()
        }

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
    func copyContextMenuPassthrough() -> some View {
        background { CopyContextMenuPassthroughMarker() }
    }
}

extension UIView {
    func textInputDescendant(
        containing point: CGPoint,
        with event: UIEvent?,
        excluding excluded: UIView
    ) -> UIView? {
        passthroughDescendant(containing: point, with: event, excluding: excluded) { view in
            view is UITextInput
        }
    }

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

enum UprightPreviewTransform {
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

    static func corrective(from layer: CALayer) -> CGAffineTransform {
        let accumulated = accumulated(from: layer)
        let determinant = accumulated.a * accumulated.d - accumulated.b * accumulated.c
        guard abs(determinant) > Constants.Conversation.CopyContextMenu.minimumInvertibleDeterminant else {
            return .identity
        }
        return accumulated.inverted()
    }
}
