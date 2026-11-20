import SwiftUI

#if os(visionOS)
struct FloatingComposerOrnament<Composer: View>: ViewModifier {
    let showsLoadingState: Bool
    let composerVisible: Bool
    let onWithdraw: () -> Void
    @ViewBuilder let composer: () -> Composer

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(ComposerCoverage.self) private var coverage: ComposerCoverage?
    @Environment(\.composerLayerDepth) private var layerDepth
    @State private var columnWidth: CGFloat = 0
    @State private var lifecycle = FloatingComposerLifecycle()

    private var isForemost: Bool {
        coverage?.isForemost(depth: layerDepth) ?? true
    }

    private var presentation: FloatingComposerPresentation {
        FloatingComposerPolicy.presentation(
            isActiveChat: lifecycle.isActiveChat,
            isForemost: isForemost,
            showsLoadingState: showsLoadingState,
            composerVisible: composerVisible
        )
    }

    private var isRevealed: Bool { presentation.revealsComposer }

    #if compiler(>=6.4)
    private var ornamentAlignment: Alignment3D { .topBack }
    #else
    private var ornamentAlignment: Alignment { .top }
    #endif

    func body(content: Content) -> some View {
        content
            .onAppear {
                lifecycle.appear(
                    isForemost: isForemost,
                    showsLoadingState: showsLoadingState,
                    composerVisible: composerVisible
                )
            }
            .onDisappear {
                if lifecycle.disappear() { onWithdraw() }
            }
            .onChange(of: presentation) { old, new in
                _ = old
                if lifecycle.applyPresentation(new) { onWithdraw() }
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                columnWidth = width
            }
            .ornament(
                visibility: isRevealed ? .visible : .hidden,
                attachmentAnchor: .scene(.bottom),
                contentAlignment: ornamentAlignment
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
        if isRevealed {
            let shape = RoundedRectangle(cornerRadius: FloatingComposerPolicy.cornerRadius, style: .continuous)
            composer()
                .padding(FloatingComposerPolicy.contentInset)
                .frame(width: FloatingComposerPolicy.width(forColumnWidth: columnWidth))
                .background {
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
