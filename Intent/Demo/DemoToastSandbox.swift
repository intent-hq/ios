#if DEBUG
import SwiftUI

/// Demo-only (`--demo-toast-sandbox`): stacks every `ToastSurface` over the live app so the
/// options can be compared against real content. Tap a banner to replay its entrance;
/// swipe up to dismiss it. Empty space passes touches through, so the list can scroll behind.
struct DemoToastSandbox: View {
    let toast: ToastInfo
    @State private var hidden: Set<ToastSurface> = []

    private enum Layout {
        static let spacing: CGFloat = 10
        static let captionSpacing: CGFloat = 4
        static let captionHorizontalPadding: CGFloat = 8
        static let captionVerticalPadding: CGFloat = 2
        static let bannerHeight: CGFloat = 64
        static let replayDelayMilliseconds = 350
    }

    var body: some View {
        VStack(spacing: Layout.spacing) {
            ForEach(ToastSurface.sandboxOrder) { surface in
                VStack(spacing: Layout.captionSpacing) {
                    Text(surface.title)
                        .interFont(Constants.Typography.subtextXXS.withFace(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Layout.captionHorizontalPadding)
                        .padding(.vertical, Layout.captionVerticalPadding)
                        .background(.thinMaterial, in: Capsule())
                    ZStack {
                        if !hidden.contains(surface) {
                            ToastView(
                                toast: toast,
                                onTap: { replay(surface) },
                                onDismiss: { replay(surface) },
                                surface: surface
                            )
                        }
                    }
                    .frame(minHeight: Layout.bannerHeight)
                }
            }
        }
        .padding(.top, Constants.Root.toastTopPadding)
        .accessibilityIdentifier("toast.sandbox")
    }

    private func replay(_ surface: ToastSurface) {
        withAnimation(.snappy) { _ = hidden.insert(surface) }
        Task {
            try? await Task.sleep(for: .milliseconds(Layout.replayDelayMilliseconds))
            withAnimation(.snappy) { _ = hidden.remove(surface) }
        }
    }
}
#endif
