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
    /// Cancels the chat's in-flight photo import. Called on genuine
    /// withdrawal only (`FloatingComposerPolicy.cancelsPhotoImport`), never
    /// because a modal covers the chat.
    let onWithdraw: () -> Void
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

    private var presentation: FloatingComposerPresentation {
        FloatingComposerPolicy.presentation(
            isActiveChat: isActiveChat,
            isForemost: coverage?.isForemost(depth: layerDepth) ?? true,
            showsLoadingState: showsLoadingState,
            composerVisible: composerVisible
        )
    }

    private var isRevealed: Bool { presentation.revealsComposer }

    func body(content: Content) -> some View {
        content
            .onAppear { isActiveChat = true }
            .onDisappear {
                isActiveChat = false
                onWithdraw()
            }
            .onChange(of: presentation) { old, new in
                if FloatingComposerPolicy.cancelsPhotoImport(from: old, to: new) { onWithdraw() }
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                columnWidth = width
            }
            .ornament(
                visibility: isRevealed ? .visible : .hidden,
                // Centered under the window's bottom edge (HIG ornament
                // placement); its top aligns there so it hangs just outside.
                attachmentAnchor: .scene(.bottom),
                contentAlignment: .topBack
            ) {
                floatingComposer
            }
            .animation(
                reduceMotion ? nil : .easeInOut(duration: Constants.Conversation.Column.chromeAnimationDuration),
                value: isRevealed
            )
    }

    @ViewBuilder
    private var floatingComposer: some View {
        // Covered or withdrawn composers are unmounted: no visible or
        // VoiceOver-reachable Send, and onDisappear stops dictation and focus.
        // On visionOS unmounting does not cancel the photo import (see onWithdraw).
        if isRevealed {
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
