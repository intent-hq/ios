import SwiftUI

struct ConversationTranscriptRowHeightFrame: ViewModifier {
    let cachedHeight: CGFloat?
    var isStreaming = false
    let onNaturalHeightChange: (CGFloat) -> Void
    @State private var lastNaturalHeight: CGFloat?

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                lastNaturalHeight = height
                onNaturalHeightChange(height)
            }
            .frame(height: cachedHeight, alignment: .top)
            .clipped()
            .onChange(of: isStreaming) { _, isStreaming in
                guard !isStreaming, let lastNaturalHeight else { return }
                onNaturalHeightChange(lastNaturalHeight)
            }
    }
}
