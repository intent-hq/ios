import SwiftUI

#if os(visionOS)
/// Hosts a chat's single composer in a glass ornament hanging just below the
/// window. The composer is the shared MessageInputView, so its draft, pending
/// attachments, uploads, dictation and send rules are the inline ones; this
/// modifier only decides placement, size and visibility
/// (`FloatingComposerPolicy`).
struct FloatingComposerOrnament<Composer: View>: ViewModifier {
    let showsLoadingState: Bool
    let composerVisible: Bool
    @ViewBuilder let composer: () -> Composer

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(ComposerCoverage.self) private var coverage: ComposerCoverage?
    @Environment(\.composerLayerDepth) private var layerDepth
    @State private var columnWidth: CGFloat = 0
    /// False while another chat is pushed over this one, so only the chat in
    /// front owns the window's composer. (Sheets and full-screen covers do
    /// not end appearance; `ComposerCoverage` handles those.)
    @State private var isActiveChat = false

    private var isPresented: Bool {
        FloatingComposerPolicy.isPresented(
            isActiveChat: isActiveChat,
            isForemost: coverage?.isForemost(depth: layerDepth) ?? true,
            showsLoadingState: showsLoadingState,
            composerVisible: composerVisible
        )
    }

    func body(content: Content) -> some View {
        content
            .onAppear { isActiveChat = true }
            .onDisappear { isActiveChat = false }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                columnWidth = width
            }
            .ornament(
                visibility: isPresented ? .visible : .hidden,
                // Centered under the window's bottom edge (HIG ornament
                // placement); its top aligns there so it hangs just outside.
                attachmentAnchor: .scene(.bottom),
                contentAlignment: .topBack
            ) {
                floatingComposer
            }
            .animation(
                reduceMotion ? nil : .easeInOut(duration: Constants.Conversation.Column.chromeAnimationDuration),
                value: isPresented
            )
    }

    @ViewBuilder
    private var floatingComposer: some View {
        if isPresented {
            let shape = RoundedRectangle(cornerRadius: FloatingComposerPolicy.cornerRadius, style: .continuous)
            composer()
                .padding(FloatingComposerPolicy.contentInset)
                .frame(width: FloatingComposerPolicy.width(forColumnWidth: columnWidth))
                .background {
                    // Reduce Transparency: an opaque surface replaces see-through glass.
                    if reduceTransparency {
                        shape.fill(Theme.card(for: colorScheme))
                    }
                }
                .glassBackgroundEffect(in: shape)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("conversation.composer.floating")
                .transition(.opacity)
        }
    }
}
#endif
