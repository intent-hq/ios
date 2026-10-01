import Foundation

nonisolated enum ConnectionSwitcherDrag {
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
}
