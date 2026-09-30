import SwiftUI

struct WorkspaceConnectionSwitcher<Content: View>: View {
    @Binding var isPresented: Bool
    let isEnabled: Bool
    let onReveal: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var width: CGFloat = 0
    @State private var safeArea = EdgeInsets()
    @State private var translation: CGFloat = 0

    private var revealWidth: CGFloat { ConnectionSwitcherDrag.revealWidth(in: width) }
    private var offset: CGFloat {
        ConnectionSwitcherDrag.offset(isOpen: isPresented, translation: translation, width: revealWidth)
    }
    private var isRevealed: Bool { isPresented || offset > 0 }
    private var revealProgress: CGFloat { offset / max(revealWidth, 1) }
    private var animation: Animation? {
        reduceMotion ? nil : .interactiveSpring(
            response: ConnectionSwitcherStyle.springResponse,
            dampingFraction: ConnectionSwitcherStyle.springDamping
        )
    }

    var body: some View {
        ZStack(alignment: layoutDirection == .rightToLeft ? .trailing : .leading) {
            ConnectionSwitcherStyle.background(for: colorScheme).ignoresSafeArea()
            ConnectionSwitcherList(
                connections: coordinator.savedConnections,
                selectedID: coordinator.backendID?.connectionID,
                onSelect: select
            )
            .frame(width: revealWidth)
            .allowsHitTesting(isPresented)
            .accessibilityHidden(!isPresented)

            slidingPage
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { safeArea = $0 }
        .mask {
            Rectangle()
                .padding(.top, -safeArea.top)
                .padding(.bottom, -safeArea.bottom)
        }
        .modifier(ConnectionSwitcherGesture(
            isEnabled: isEnabled,
            isOpen: isPresented,
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
        content()
            .scrollDisabled(isRevealed)
            .allowsHitTesting(!isRevealed)
            .accessibilityHidden(isRevealed)
            .overlay {
                if isRevealed {
                    Button { close() } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close connection switcher")
                    .accessibilityIdentifier("connection-switcher.close")
                    .transition(.identity)
                }
            }
            .background(Constants.WorkspaceList.canvas(for: colorScheme).ignoresSafeArea())
            .mask {
                RoundedRectangle(cornerRadius: ConnectionSwitcherStyle.pageCornerRadius * revealProgress, style: .continuous)
                    .padding(.top, -safeArea.top)
                    .padding(.bottom, -safeArea.bottom)
            }
            .shadow(color: .black.opacity(ConnectionSwitcherStyle.shadowOpacity * Double(revealProgress)), radius: ConnectionSwitcherStyle.shadowRadius)
            .offset(x: offset)
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
            isPresented = ConnectionSwitcherDrag.shouldOpen(
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

    private func select(_ id: UUID) {
        close()
        if id != coordinator.backendID?.connectionID {
            coordinator.onSwitchConnection(id: id)
        }
    }
}
