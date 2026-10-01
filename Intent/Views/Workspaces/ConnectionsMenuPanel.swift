import SwiftUI

/// Matched-geometry identities shared by a home action tile and the panel it expands into.
enum HomeActionMorph: Hashable {
    case content(HomeActionTiles.Action)
    case surface(HomeActionTiles.Action)

    /// Each side appears opaque and fades only on removal, so the morphing surface never
    /// turns translucent while the outgoing and incoming shapes overlap.
    static let surfaceTransition = AnyTransition.asymmetric(insertion: .identity, removal: .opacity)
}

/// The Intent menu's connections tile, expanded in place into the saved-connection list.
struct ConnectionsMenuPanel: View {
    let namespace: Namespace.ID
    let onBack: () -> Void
    let onDismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var isTitleFocused: Bool
    @State private var isRevealed = false

    private enum Layout {
        static let inset = Constants.ConnectionSheet.inset
        static let topPadding: CGFloat = 44
        static let headingToCardsSpacing: CGFloat = 40
        static let cornerRadius = Constants.ConnectionSheet.cornerRadius
        static let revealDuration = 0.3
        static let revealDelay = 0.05
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.inset) {
            IdealHeightLayout {
                ScrollView {
                    SavedConnectionsContent(
                        headerAlignment: .leading,
                        headerSpacing: Layout.headingToCardsSpacing,
                        onDismiss: onDismiss
                    ) { count in
                        title(count: count)
                    }
                    .padding(.top, Layout.topPadding)
                    .padding(.horizontal, Layout.inset)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            backButton
                .padding(.horizontal, Layout.inset)
        }
        .padding(.bottom, Layout.inset)
        .opacity(isRevealed ? 1 : 0)
        .matchedGeometryEffect(
            id: HomeActionMorph.content(.connections),
            in: namespace,
            properties: .position,
            anchor: .topLeading
        )
        .background {
            // Starts as the tile's surface and settles into the list's background and corners.
            RoundedRectangle(
                cornerRadius: isRevealed ? Layout.cornerRadius : HomeActionTiles.cornerRadius,
                style: .continuous
            )
            .fill(isRevealed
                ? Constants.Connections.background(for: colorScheme)
                : Constants.WorkspaceList.controlSurface(for: colorScheme))
            .matchedGeometryEffect(id: HomeActionMorph.surface(.connections), in: namespace)
        }
        .accessibilityElement(children: .contain)
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: Layout.revealDuration).delay(Layout.revealDelay)) {
                isRevealed = true
            }
            isTitleFocused = true
        }
    }

    private func title(count: Int) -> some View {
        ConnectionSheetText(
            "\(HomeActionTiles.connectionsTitle(count: count))",
            style: Constants.Typography.heading2,
            tracking: Constants.Connections.headingTracking
        )
        .foregroundStyle(Constants.Connections.foreground(for: colorScheme))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("saved-connections.title")
        .accessibilityFocused($isTitleFocused)
    }

    private var backButton: some View {
        Button(action: onBack) {
            Image(.arrowLeft)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: Constants.ConnectionSheet.glyphSize, height: Constants.ConnectionSheet.glyphSize)
                .frame(width: Constants.ConnectionSheet.closeSize, height: Constants.ConnectionSheet.closeSize)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Constants.Connections.foreground(for: colorScheme))
        .accessibilityLabel("Back")
        .accessibilityHint("Returns to the Intent menu.")
        .accessibilityIdentifier("intent.menu.connections.back")
    }
}

/// Sizes its single subview to its ideal height, capped by the proposal, so a scroll view
/// hugs short content and only scrolls once the content outgrows the available space.
private struct IdealHeightLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, proposal.height ?? ideal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
