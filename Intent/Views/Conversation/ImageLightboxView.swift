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
    var data: Data? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @State private var gestureScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragTranslation: CGSize = .zero
    @State private var viewportSize: CGSize = .zero

    private static let minScale: CGFloat = 1
    private static let maxScale: CGFloat = 5
    private static let doubleTapScale: CGFloat = 2.5
    private static let dismissDragThreshold: CGFloat = 120

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale * gestureScale)
                .offset(x: offset.width + dragTranslation.width,
                        y: offset.height + dragTranslation.height)
                .gesture(doubleTapGesture)
                .gesture(dragGesture(in: viewportSize))
                .simultaneousGesture(magnifyGesture(in: viewportSize))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            if size.width > 0, size.height > 0 {
                viewportSize = size
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                actionsMenu
                closeButton
            }
            .padding(12)
        }
        .background(Color.black.ignoresSafeArea())
    }

    private var actionsMenu: some View {
        Menu {
            ImageActionMenuItems(image: image, originalData: data)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.white.opacity(0.15), in: Circle())
        }
        .accessibilityLabel("Image actions")
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.white.opacity(0.15), in: Circle())
        }
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
                    let raw = CGSize(width: offset.width + value.translation.width,
                                     height: offset.height + value.translation.height)
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
        ImageLightboxLayout.clampedOffset(
            proposed,
            imageSize: image.size,
            scale: scale,
            minimumScale: Self.minScale,
            in: container
        )
    }
}

enum ImageLightboxLayout {
    static func clampedOffset(
        _ proposed: CGSize,
        imageSize: CGSize,
        scale: CGFloat,
        minimumScale: CGFloat,
        in container: CGSize
    ) -> CGSize {
        guard scale > minimumScale, imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let fitRatio = min(container.width / imageSize.width, container.height / imageSize.height)
        let fitted = CGSize(width: imageSize.width * fitRatio, height: imageSize.height * fitRatio)
        let maxX = max(0, (fitted.width * scale - container.width) / 2)
        let maxY = max(0, (fitted.height * scale - container.height) / 2)
        return CGSize(width: min(max(proposed.width, -maxX), maxX),
                      height: min(max(proposed.height, -maxY), maxY))
    }
}
