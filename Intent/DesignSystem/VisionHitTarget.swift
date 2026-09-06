import SwiftUI

extension Constants.Accessibility {
    /// visionOS list-row hit target: 60 pt tall rows keep adjacent row centers
    /// >= 60 pt apart while comfortably exceeding the 44 pt minimum target.
    static let visionListRowMinimumHeight: CGFloat = 60
}

extension View {
    /// visionOS eyes/hands ergonomics for custom-styled row buttons: grow the
    /// hit region to a 60 pt minimum height (>= 44 pt targets with >= 60 pt
    /// center spacing between stacked rows), make the whole area tappable, and
    /// add hover feedback. No-op on iOS so the existing layout is untouched.
    func visionListRowHitTarget() -> some View {
        #if os(visionOS)
        return self
            .frame(minHeight: Constants.Accessibility.visionListRowMinimumHeight)
            .contentShape(Rectangle())
            .hoverEffect()
        #else
        return self
        #endif
    }
}
