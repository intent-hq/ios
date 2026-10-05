import Foundation

/// The physical screen side a drawer slides out from.
nonisolated enum EdgeDrawerSide {
    case left
    case right
}

/// Drag rules shared by the edge drawers. Every value is in the drawer's
/// opening frame: distances from its own edge, positive toward opening.
nonisolated enum EdgeDrawerDrag {
    static let edgeWidth: CGFloat = 24
    static let maximumReveal: CGFloat = 320
    static let pagePeek: CGFloat = 82
    static let flickVelocity: CGFloat = 500

    static func revealWidth(in width: CGFloat) -> CGFloat {
        max(0, min(maximumReveal, width - pagePeek))
    }

    static func canBegin(isOpen: Bool, startX: CGFloat, velocity: CGPoint) -> Bool {
        guard abs(velocity.x) > abs(velocity.y) else { return false }
        return isOpen || (startX >= 0 && startX <= edgeWidth && velocity.x > 0)
    }

    static func offset(isOpen: Bool, translation: CGFloat, width: CGFloat) -> CGFloat {
        min(width, max(0, (isOpen ? width : 0) + translation))
    }

    static func shouldOpen(isOpen: Bool, translation: CGFloat, velocity: CGFloat, width: CGFloat) -> Bool {
        guard width > 0 else { return false }
        if abs(velocity) >= flickVelocity { return velocity > 0 }
        return offset(isOpen: isOpen, translation: translation, width: width) > width / 2
    }

    /// Converts a horizontal screen-space translation or velocity into the opening frame.
    static func towardOpening(_ value: CGFloat, side: EdgeDrawerSide) -> CGFloat {
        side == .left ? value : -value
    }

    /// Converts a screen-space x position into the distance from the drawer's edge.
    static func distanceFromEdge(_ x: CGFloat, width: CGFloat, side: EdgeDrawerSide) -> CGFloat {
        side == .left ? x : width - x
    }
}
