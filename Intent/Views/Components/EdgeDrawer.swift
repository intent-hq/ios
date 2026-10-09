import SwiftUI

/// A panel revealed by sliding the page away from one physical screen edge.
/// Shared by the Connections switcher (left) and the agent history (right).
struct EdgeDrawer<Panel: View, Content: View>: View {
    let side: EdgeDrawerSide
    @Binding var isPresented: Bool
    let isEnabled: Bool
    let closeLabel: LocalizedStringKey
    let closeIdentifier: String
    let onReveal: () -> Void
    @ViewBuilder let panel: Panel
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.workspaceUsesVerticalBar) private var usesVerticalBar
    @State private var width: CGFloat = 0
    @State private var safeArea = EdgeInsets()
    @State private var translation: CGFloat = 0

    private var revealWidth: CGFloat { EdgeDrawerDrag.revealWidth(in: width) }
    private var offset: CGFloat {
        EdgeDrawerDrag.offset(isOpen: isPresented, translation: translation, width: revealWidth)
    }
    private var isRevealed: Bool { isPresented || offset > 0 }
    private var revealProgress: CGFloat { offset / max(revealWidth, 1) }
    /// Offsets are physical, so the panel pins to its physical side in both layout directions.
    private var panelAlignment: Alignment {
        (side == .left) == (layoutDirection == .leftToRight) ? .leading : .trailing
    }
    private var animation: Animation? {
        reduceMotion ? nil : .interactiveSpring(
            response: ConnectionSwitcherStyle.springResponse,
            dampingFraction: ConnectionSwitcherStyle.springDamping
        )
    }

    var body: some View {
        ZStack(alignment: panelAlignment) {
            ConnectionSwitcherStyle.background(for: colorScheme).ignoresSafeArea()
            panel
                .frame(width: revealWidth)
                .allowsHitTesting(isPresented)
                .accessibilityHidden(!isPresented)

            slidingPage
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { safeArea = $0 }
        .mask {
            if usesVerticalBar {
                Rectangle()
                    .padding(.top, -safeArea.top)
                    .padding(.bottom, -safeArea.bottom)
                    .padding(.leading, -safeArea.leading)
                    .padding(.trailing, -safeArea.trailing)
            } else {
                Rectangle()
                    .padding(.top, -safeArea.top)
                    .padding(.bottom, -safeArea.bottom)
            }
        }
        .modifier(EdgeDrawerGesture(
            side: side,
            isEnabled: isEnabled,
            isOpen: $isPresented,
            onChanged: drag,
            onEnded: finish,
            onCancelled: cancelDrag
        ))
        .accessibilityAction(.escape, close)
        .onChange(of: isRevealed) { _, revealed in
            if revealed { onReveal() }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { close() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { close() }
        }
        .onDisappear {
            isPresented = false
            translation = 0
        }
        .animation(animation, value: isPresented)
    }

    private var slidingPage: some View {
        content
            .scrollDisabled(isRevealed)
            .allowsHitTesting(!isRevealed)
            .accessibilityHidden(isRevealed)
            .overlay {
                if isRevealed {
                    Button { close() } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(IntentContentButtonStyle())
                    .accessibilityLabel(closeLabel)
                    .accessibilityIdentifier(closeIdentifier)
                    .transition(.identity)
                }
            }
            .background(Constants.WorkspaceList.canvas(for: colorScheme).ignoresSafeArea())
            .mask {
                if usesVerticalBar {
                    RoundedRectangle(cornerRadius: ConnectionSwitcherStyle.pageCornerRadius * revealProgress, style: .continuous)
                        .padding(.top, -safeArea.top)
                        .padding(.bottom, -safeArea.bottom)
                        .padding(.leading, -safeArea.leading)
                        .padding(.trailing, -safeArea.trailing)
                } else {
                    RoundedRectangle(cornerRadius: ConnectionSwitcherStyle.pageCornerRadius * revealProgress, style: .continuous)
                        .padding(.top, -safeArea.top)
                        .padding(.bottom, -safeArea.bottom)
                }
            }
            .shadow(
                color: .black.opacity(ConnectionSwitcherStyle.shadowOpacity * Double(revealProgress)),
                radius: isRevealed ? ConnectionSwitcherStyle.shadowRadius : 0
            )
            .offset(x: EdgeDrawerDrag.towardOpening(offset, side: side))
    }

    private func drag(_ distance: CGFloat) {
        var transaction = Transaction(animation: nil)
        transaction.isContinuous = true
        transaction.tracksVelocity = true
        withTransaction(transaction) { translation = distance }
    }

    private func cancelDrag() {
        withAnimation(animation) { translation = 0 }
    }

    private func finish(_ distance: CGFloat, _ velocity: CGFloat) {
        withAnimation(animation) {
            isPresented = EdgeDrawerDrag.shouldOpen(
                isOpen: isPresented, translation: distance, velocity: velocity, width: revealWidth
            )
            translation = 0
        }
    }

    private func close() {
        withAnimation(animation) {
            isPresented = false
            translation = 0
        }
    }
}
