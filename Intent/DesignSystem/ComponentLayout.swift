import SwiftUI

extension Constants {
    enum TaskStatusIcon {
        static let defaultSize: CGFloat = 16
        static let referenceSize: CGFloat = 24
        static let standardStrokeWidth: CGFloat = 2.5
        static let increasedContrastStrokeWidth: CGFloat = 3.5
        static let increasedContrastNeutralOpacity: Double = 0.75
        static let fullFillRadius: CGFloat = 12
        static let inProgressFillRadius: CGFloat = 6.6
        static let outerCircleDiameter: CGFloat = 21.6
        static let inProgressInnerStrokeWidth: CGFloat = 2
        static let inProgressInnerDiameter: CGFloat = 20
        static let diameterMultiplier: CGFloat = 2
        static let inProgressClipLeadingX: CGFloat = 11.52
        static let secondaryGlyphSize: CGFloat = 11
        static let questionGlyphSize: CGFloat = 12
        static let eyeGlyphSize: CGFloat = 10
        static let blockedGlyphStrokeWidth: CGFloat = 3
        static let blockedDotDiameter: CGFloat = 3.2
        static let blockedDotOffset: CGFloat = 5.5
        static let completeGlyphStrokeWidth: CGFloat = 3.5
    }

    enum TaskProgressRing {
        static let defaultSize: CGFloat = 14
        static let referenceSize: CGFloat = 14
        static let standardStrokeWidth: CGFloat = 2.5
        static let increasedStrokeWidth: CGFloat = 3.25
        static let increasedTrackOpacity: Double = 0.65
        static let differentiatedDashMultiplier: CGFloat = 1.5
        static let startAngle = Angle.radians(-.pi / 2)
    }

    /// Shape geometry must remain readable outside the main actor.
    nonisolated enum IntentLogo {
        static let viewBoxSize: CGFloat = 24
        static let strokeWidth: CGFloat = 2.06
    }

    enum CertMismatch {
        static let contentSpacing: CGFloat = 8
        static let hostSpacing: CGFloat = 1
        static let verticalPadding: CGFloat = 10
        static let horizontalPadding: CGFloat = 12
        static let backgroundOpacity: Double = 0.12
        static let cornerRadius: CGFloat = 12
    }
}

extension Constants.AgentAvatar {
    static let defaultSize: CGFloat = 20
}

extension Constants.RepoOwnerAvatar {
    static let defaultSize: CGFloat = 28
}
