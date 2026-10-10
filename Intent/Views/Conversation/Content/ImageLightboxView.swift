import SwiftUI

/// Fullscreen image viewer with pinch-to-zoom, drag-to-pan while zoomed,
/// double-tap zoom toggle, and dismissal via the close button, a backdrop
/// tap, or a swipe-down while unzoomed (FE parity: ImageLightbox.svelte).
/// An ellipsis menu next to the close button offers Save/Copy plus the
/// image's dimensions and file size.
struct ImageLightboxView: View {
    let image: UIImage
    /// Original encoded bytes when known (base64 image blocks) so the
    /// info rows show the real file size.
    var data: Data?
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var actionIconSide: CGFloat = 17

    @State private var scale: CGFloat = 1
    @State private var gestureScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragTranslation: CGSize = .zero
    @State private var viewportSize: CGSize = .zero

    private static let minScale: CGFloat = 1
    private static let maxScale: CGFloat = 5
    private static let doubleTapScale: CGFloat = 2.5
    private static let dismissDragThreshold: CGFloat = 120
    private static let zoomPercentageMultiplier: CGFloat = 100
    private static let accessibilityPanDistance: CGFloat = 50

    var body: some View {
        ZStack {
            backdrop
            imagePreview
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            if size.width > 0, size.height > 0 {
                viewportSize = size
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: Constants.Conversation.ImageLightbox.actionSpacing) {
                actionsMenu
                closeButton
            }
            .padding(Constants.Conversation.ImageLightbox.actionContainerPadding)
        }
        .onAppear {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
        }
    }

    private var backdrop: some View {
        Button { dismiss() } label: {
            Color.black
                .ignoresSafeArea()
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityHidden(true)
    }

    private var imagePreview: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale * gestureScale)
            .offset(
                x: offset.width + dragTranslation.width,
                y: offset.height + dragTranslation.height
            )
            .accessibilityLabel("Image preview")
            .accessibilityValue("\(Int(scale * Self.zoomPercentageMultiplier)) percent zoom")
            .accessibilityAdjustableAction { direction in
                adjustZoom(direction, in: viewportSize)
            }
            .accessibilityActions {
                imageAccessibilityActions
            }
            .gesture(doubleTapGesture)
            .gesture(dragGesture(in: viewportSize))
            .simultaneousGesture(magnifyGesture(in: viewportSize))
    }

    @ViewBuilder
    private var imageAccessibilityActions: some View {
        if scale > Self.minScale {
            Button("Pan left") {
                panImage(by: CGSize(width: -Self.accessibilityPanDistance, height: 0), in: viewportSize)
            }
            Button("Pan right") {
                panImage(by: CGSize(width: Self.accessibilityPanDistance, height: 0), in: viewportSize)
            }
            Button("Pan up") {
                panImage(by: CGSize(width: 0, height: -Self.accessibilityPanDistance), in: viewportSize)
            }
            Button("Pan down") {
                panImage(by: CGSize(width: 0, height: Self.accessibilityPanDistance), in: viewportSize)
            }
            Button("Reset zoom") {
                scale = Self.minScale
                gestureScale = 1
                offset = .zero
            }
        }
    }

    private var actionsMenu: some View {
        Menu {
            ImageActionMenuItems(image: image, originalData: data)
        } label: {
            Image(.more)
                .resizable()
                .scaledToFit()
                .accessibilityHidden(true)
                .frame(width: actionIconSide, height: actionIconSide)
                .foregroundStyle(.white)
                .padding(Constants.Conversation.ImageLightbox.actionButtonPadding)
                .background(.white.opacity(Constants.Conversation.ImageLightbox.actionButtonBackgroundOpacity), in: Circle())
                .frame(
                    minWidth: Constants.Accessibility.minimumTapTarget,
                    minHeight: Constants.Accessibility.minimumTapTarget
                )
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel("Image actions")
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(.close)
                .resizable()
                .scaledToFit()
                .accessibilityHidden(true)
                .frame(width: actionIconSide, height: actionIconSide)
                .foregroundStyle(.white)
                .padding(Constants.Conversation.ImageLightbox.actionButtonPadding)
                .background(.white.opacity(Constants.Conversation.ImageLightbox.actionButtonBackgroundOpacity), in: Circle())
                .frame(
                    minWidth: Constants.Accessibility.minimumTapTarget,
                    minHeight: Constants.Accessibility.minimumTapTarget
                )
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel("Close image")
    }

    // MARK: - Gestures

    private var doubleTapGesture: some Gesture {
        TapGesture(count: 2).onEnded {
            withAnimation(.spring(duration: Constants.Conversation.ImageLightbox.springAnimationDuration)) {
                if scale > Self.minScale {
                    scale = Self.minScale
                    offset = .zero
                } else {
                    scale = Self.doubleTapScale
                }
            }
        }
    }

    private func adjustZoom(_ direction: AccessibilityAdjustmentDirection, in size: CGSize) {
        let step: CGFloat = 0.5
        switch direction {
        case .increment:
            scale = min(scale + step, Self.maxScale)
        case .decrement:
            scale = max(scale - step, Self.minScale)
            offset = clampedOffset(offset, in: size)
        @unknown default:
            break
        }
    }

    private func panImage(by delta: CGSize, in size: CGSize) {
        offset = clampedOffset(
            CGSize(width: offset.width + delta.width, height: offset.height + delta.height),
            in: size
        )
    }

    private func magnifyGesture(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                gestureScale = value.magnification
            }
            .onEnded { value in
                scale = min(max(scale * value.magnification, Self.minScale), Self.maxScale)
                gestureScale = 1
                withAnimation(.spring(duration: Constants.Conversation.ImageLightbox.springAnimationDuration)) {
                    offset = clampedOffset(offset, in: size)
                }
            }
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if scale > Self.minScale {
                    dragTranslation = value.translation
                } else {
                    // Unzoomed: vertical pull tracks the finger as dismissal feedback.
                    dragTranslation = CGSize(width: 0, height: max(0, value.translation.height))
                }
            }
            .onEnded { value in
                if scale > Self.minScale {
                    let raw = CGSize(
                        width: offset.width + value.translation.width,
                        height: offset.height + value.translation.height
                    )
                    dragTranslation = .zero
                    withAnimation(.spring(duration: Constants.Conversation.ImageLightbox.springAnimationDuration)) {
                        offset = clampedOffset(raw, in: size)
                    }
                } else if value.translation.height > Self.dismissDragThreshold {
                    dismiss()
                } else {
                    withAnimation(.spring(duration: Constants.Conversation.ImageLightbox.springAnimationDuration)) {
                        dragTranslation = .zero
                    }
                }
            }
    }

    /// Keep the zoomed image edge-locked to the viewport: no panning past the
    /// fitted image's scaled bounds, and no panning at all while unzoomed.
    private func clampedOffset(_ proposed: CGSize, in container: CGSize) -> CGSize {
        guard scale > Self.minScale, image.size.width > 0, image.size.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let fitRatio = min(container.width / image.size.width, container.height / image.size.height)
        let fitted = CGSize(width: image.size.width * fitRatio, height: image.size.height * fitRatio)
        let maxX = max(0, (fitted.width * scale - container.width) / 2)
        let maxY = max(0, (fitted.height * scale - container.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }
}
