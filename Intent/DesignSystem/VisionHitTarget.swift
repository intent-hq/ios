import SwiftUI

extension Constants.Accessibility {
    static let visionListRowMinimumHeight: CGFloat = 60
    static let visionChevronHoverPadding: CGFloat = 8
}

extension Constants.WorkspaceSearch {
    static var visionSegmentSpacing: CGFloat {
        #if os(visionOS)
        contentSpacing
        #else
        0
        #endif
    }
}

extension EnvironmentValues {
    @Entry var visionContainerDrawsHover = false
}

extension View {
    @ViewBuilder
    func visionButtonHover(isEnabled: Bool = true) -> some View {
        #if os(visionOS)
        self.hoverEffect(.highlight, isEnabled: isEnabled)
        #else
        self
        #endif
    }

    @ViewBuilder
    func visionHoverShape(_ shape: some Shape) -> some View {
        #if os(visionOS)
        self.contentShape(.hoverEffect, shape)
        #else
        self
        #endif
    }

    @ViewBuilder
    func visionGroupedHoverHint(padding: CGFloat) -> some View {
        #if os(visionOS)
        self
            .padding(padding)
            .contentShape(.hoverEffect, Circle())
            .hoverEffect(.highlight)
            .padding(-padding)
        #else
        self
        #endif
    }

    @ViewBuilder
    func visionHoverGroup() -> some View {
        #if os(visionOS)
        self.hoverEffectGroup()
        #else
        self
        #endif
    }

    func visionContainerDrawsHover(_ drawsHover: Bool = true) -> some View {
        environment(\.visionContainerDrawsHover, drawsHover)
    }

    @ViewBuilder
    func visionWorkspaceControlHover(cornerRadius: CGFloat, isEnabled: Bool = true) -> some View {
        #if os(visionOS)
        if isEnabled {
            self
                .contentShape([.interaction, .hoverEffect], .rect(cornerRadius: cornerRadius))
                .hoverEffect(.highlight)
        } else {
            self
        }
        #else
        self
        #endif
    }

    func visionListRowHitTarget() -> some View {
        #if os(visionOS)
        return self
            .visionContainerDrawsHover()
            .frame(minHeight: Constants.Accessibility.visionListRowMinimumHeight)
            .contentShape(Rectangle())
            .hoverEffect()
        #else
        return self
        #endif
    }

    func visionCardRowButton(cornerRadius: CGFloat) -> some View {
        #if os(visionOS)
        return self
            .buttonStyle(IntentContentButtonStyle())
            .visionContainerDrawsHover()
            .frame(minHeight: Constants.Accessibility.visionListRowMinimumHeight)
            .contentShape(.hoverEffect, .rect(cornerRadius: cornerRadius))
            .hoverEffect()
        #else
        return self
        #endif
    }
}
