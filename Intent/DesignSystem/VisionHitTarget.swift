import SwiftUI

extension Constants.Accessibility {
    /// visionOS list-row hit target: 60 pt tall rows keep adjacent row centers
    /// >= 60 pt apart while comfortably exceeding the 44 pt minimum target.
    static let visionListRowMinimumHeight: CGFloat = 60
}

extension Constants.WorkspaceSearch {
    /// Leave room between the individual gaze highlights without changing iOS.
    static var visionSegmentSpacing: CGFloat {
        #if os(visionOS)
        contentSpacing
        #else
        0
        #endif
    }
}

extension EnvironmentValues {
    /// True below a row or label that draws the gaze highlight itself, so
    /// `IntentContentButtonStyle` does not stack a second one (visionOS).
    @Entry var visionContainerDrawsHover = false
}

extension View {
    /// visionOS gaze highlight for a custom-styled button (HIG: every
    /// interactive element shows hover feedback). No-op elsewhere.
    @ViewBuilder
    func visionButtonHover(isEnabled: Bool = true) -> some View {
        #if os(visionOS)
        self.hoverEffect(.highlight, isEnabled: isEnabled)
        #else
        self
        #endif
    }

    /// The visible shape the gaze highlight follows. Apply as the label's
    /// last modifier so the button style's highlight picks it up. No-op
    /// elsewhere.
    @ViewBuilder
    func visionHoverShape(_ shape: some Shape) -> some View {
        #if os(visionOS)
        self.contentShape(.hoverEffect, shape)
        #else
        self
        #endif
    }

    /// visionOS: highlights only this small view (a disclosure chevron)
    /// while its enclosing `visionHoverGroup()` is looked at. The negative
    /// padding keeps layout unchanged. No-op elsewhere.
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

    /// visionOS: looking anywhere in this view activates its descendants'
    /// hover effects together. No-op elsewhere.
    @ViewBuilder
    func visionHoverGroup() -> some View {
        #if os(visionOS)
        self.hoverEffectGroup()
        #else
        self
        #endif
    }

    /// Marks the buttons below as highlighted by this container on visionOS.
    func visionContainerDrawsHover(_ drawsHover: Bool = true) -> some View {
        environment(\.visionContainerDrawsHover, drawsHover)
    }

    /// Apply inside each workspace control's label, after its frame, so the
    /// custom button style keeps a single, shaped gaze target per action.
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

    /// visionOS eyes/hands ergonomics for custom-styled row buttons: grow the
    /// hit region to a 60 pt minimum height (>= 44 pt targets with >= 60 pt
    /// center spacing between stacked rows), make the whole area tappable, and
    /// add hover feedback. No-op on iOS so the existing layout is untouched.
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

    /// visionOS treatment for buttons whose label already draws its own rounded
    /// card: drop the automatic bordered capsule (`.plain` style) and give the
    /// gaze hover highlight the card's rounded-rectangle shape, keeping the
    /// 60 pt minimum row height. No-op on iOS so the existing layout and the
    /// default button style are untouched.
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
