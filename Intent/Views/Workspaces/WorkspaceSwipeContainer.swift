import SwiftUI

enum WorkspaceSwipeTarget: Hashable {
    case assistant(String)
    case browser(String)
    case script(String)
    case terminal(String)
    case workspace(String)
}

struct WorkspaceSwipeContainer<Content: View, Actions: View>: View {
    let target: WorkspaceSwipeTarget
    @Binding var revealedTarget: WorkspaceSwipeTarget?
    let actionCount: Int
    var actionWidth: CGFloat?
    var actionLeadingSpacing: CGFloat = WorkspaceSwipeStyle.spacing
    var rowBackground: Color = .clear
    var restingCornerRadius: CGFloat = 0
    var horizontalInset: CGFloat = 0
    var showsSwipeTint = true
    var swipeBackground: Color?
    var leadingSwipeWidth: CGFloat = 0
    var isSwipeEnabled = true
    var onLeadingSwipeCompleted: () -> Void = {}
    var onOffsetChanged: (CGFloat) -> Void = { _ in }
    var onSwipeProgressChanged: (CGFloat) -> Void = { _ in }
    @ViewBuilder var content: (_ swipeProgress: CGFloat) -> Content
    @ViewBuilder var actions: () -> Actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .body) private var defaultActionWidth = WorkspaceSwipeStyle.buttonWidth
    @State private var offset: CGFloat = 0
    @State private var dragOrigin: CGFloat?
    @State private var actionsVisible = false
    @State private var animationRevision = 0

    private var isRevealed: Bool { revealedTarget == target }
    private var revealWidth: CGFloat {
        guard actionCount > 0 else { return 0 }
        return CGFloat(actionCount) * (actionWidth ?? defaultActionWidth)
            + CGFloat(max(0, actionCount - 1)) * WorkspaceSwipeStyle.spacing
            + actionLeadingSpacing
    }
    private var restingOffset: CGFloat { isRevealed ? -revealWidth : 0 }
    private var swipeProgress: CGFloat {
        min(1, abs(offset) / max(offset > 0 ? leadingSwipeWidth : revealWidth, 1))
    }
    private var leadingSwipeArmed: Bool { leadingSwipeWidth > 0 && offset >= leadingSwipeWidth }
    private var rowCornerRadius: CGFloat {
        restingCornerRadius + (WorkspaceSwipeStyle.rowCornerRadius - restingCornerRadius) * swipeProgress
    }
    private var rowTintOpacity: Double {
        guard showsSwipeTint else { return 0 }
        if swipeBackground != nil { return Double(swipeProgress) }
        let opacity = contrast == .increased ? WorkspaceSwipeStyle.increasedTintOpacity : WorkspaceSwipeStyle.tintOpacity
        return Double(swipeProgress) * opacity
    }

    var body: some View {
        content(swipeProgress)
            .background(rowBackground.opacity(1 - Double(swipeProgress)), in: .rect(cornerRadius: restingCornerRadius))
            .padding(.leading, horizontalInset)
            .background {
                (swipeBackground ?? (colorScheme == .dark ? Color.white : Color.black)).opacity(rowTintOpacity)
            }
            .clipShape(RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous))
            .offset(x: offset)
            .padding(.trailing, horizontalInset)
            .overlay(alignment: .trailing) {
                if actionsVisible {
                    HStack(spacing: WorkspaceSwipeStyle.spacing, content: actions)
                        .padding(.leading, actionLeadingSpacing)
                        .fixedSize(horizontal: true, vertical: false)
                        .scaleEffect(reduceMotion ? 1 : swipeProgress, anchor: .trailing)
                        .offset(x: reduceMotion ? revealWidth + offset : 0)
                        .animation(reduceMotion ? nil : WorkspaceSwipeStyle.spring, value: swipeProgress)
                        .padding(.trailing, horizontalInset)
                        .allowsHitTesting(isRevealed && dragOrigin == nil)
                        .accessibilityHidden(!isRevealed || dragOrigin != nil)
                        .transition(.identity)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .modifier(WorkspaceRowSwipeGesture(onChanged: drag, onEnded: finish, onCancelled: settle))
            .onChange(of: leadingSwipeArmed) { _, armed in
                if armed { HapticManager.impact(.light) }
            }
            .onChange(of: isRevealed) { _, _ in
                if offset != restingOffset { settle() }
            }
            .onChange(of: revealWidth) { _, _ in settle() }
            .onChange(of: isSwipeEnabled) { _, enabled in
                if !enabled { settle() }
            }
            .onDisappear {
                animationRevision += 1
                dragOrigin = nil
                offset = 0
                actionsVisible = false
                if isRevealed { revealedTarget = nil }
                onSwipeProgressChanged(0)
                onOffsetChanged(0)
            }
    }

    private func drag(_ distance: CGFloat) {
        guard isSwipeEnabled else { return }
        if dragOrigin == nil {
            animationRevision += 1
            dragOrigin = offset
            if !isRevealed { revealedTarget = nil }
        }
        withTransaction(Transaction(animation: nil)) {
            offset = WorkspaceSwipePolicy.offset(
                translation: distance,
                origin: dragOrigin ?? 0,
                leadingWidth: leadingSwipeWidth,
                trailingWidth: revealWidth
            )
            actionsVisible = offset < 0
            onSwipeProgressChanged(swipeProgress)
            onOffsetChanged(offset)
        }
    }

    private func finish(_ distance: CGFloat) {
        guard isSwipeEnabled, let dragOrigin else { settle(); return }
        if WorkspaceSwipePolicy.completesLeadingSwipe(
            translation: distance,
            origin: dragOrigin,
            leadingWidth: leadingSwipeWidth
        ) {
            revealedTarget = nil
            settle()
            onLeadingSwipeCompleted()
            return
        }
        if revealWidth > 0, distance < -WorkspaceSwipeStyle.revealThreshold {
            revealedTarget = target
        } else if distance > WorkspaceSwipeStyle.revealThreshold, isRevealed {
            revealedTarget = nil
        }
        settle()
    }

    private func settle() {
        dragOrigin = nil
        animationRevision += 1
        let revision = animationRevision
        if isRevealed { actionsVisible = true }
        withAnimation(reduceMotion ? nil : WorkspaceSwipeStyle.spring, completionCriteria: .removed) {
            offset = restingOffset
            onSwipeProgressChanged(swipeProgress)
            onOffsetChanged(offset)
        } completion: {
            if animationRevision == revision, !isRevealed, dragOrigin == nil {
                actionsVisible = false
            }
        }
    }
}

struct WorkspaceSwipeIconButtonStyle: ButtonStyle {
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .foregroundStyle(configuration.role == .destructive
                ? Theme.destructive(for: colorScheme)
                : Constants.Pairing.foreground(for: colorScheme))
            .background(
                Constants.WorkspaceList.controlSurface(for: colorScheme),
                in: .rect(cornerRadius: Constants.WorkspaceList.swipeButtonCornerRadius)
            )
            .contentShape(.rect(cornerRadius: Constants.WorkspaceList.swipeButtonCornerRadius))
            .opacity(isEnabled ? (configuration.isPressed ? WorkspaceSwipeStyle.pressedOpacity : 1) : WorkspaceSwipeStyle.disabledOpacity)
    }
}

struct WorkspaceSwipeButtonStyle: ButtonStyle {
    let color: Color
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .body) private var width = WorkspaceSwipeStyle.buttonWidth

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .interFont(Constants.Typography.bodyXS)
            .padding(.vertical, WorkspaceSwipeStyle.verticalPadding)
            .frame(width: width)
            .frame(minHeight: Constants.Accessibility.minimumTapTarget)
            .foregroundStyle(.white)
            .background(color, in: .rect(cornerRadius: WorkspaceSwipeStyle.cornerRadius))
            .opacity(isEnabled ? (configuration.isPressed ? WorkspaceSwipeStyle.pressedOpacity : 1) : WorkspaceSwipeStyle.disabledOpacity)
    }
}

private enum WorkspaceSwipeStyle {
    static let buttonWidth: CGFloat = 88
    static let spacing: CGFloat = 8
    static let cornerRadius: CGFloat = 8
    static let rowCornerRadius: CGFloat = 24
    static let tintOpacity = 0.08
    static let increasedTintOpacity = 0.14
    static let verticalPadding: CGFloat = 12
    static let revealThreshold: CGFloat = 30
    static let springResponse = 0.28
    static let springDamping = 0.82
    static let spring = Animation.interactiveSpring(response: springResponse, dampingFraction: springDamping)
    static let pressedOpacity = 0.75
    static let disabledOpacity = 0.5
}
