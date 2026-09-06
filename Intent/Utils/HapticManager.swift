import UIKit

#if os(visionOS)
/// visionOS has no haptics hardware and marks the UIFeedbackGenerator family
/// unavailable, so keep the same call-site API as no-ops. The nested enums
/// mirror the UIKit case names used by call sites (dot-shorthand compatible).
enum HapticManager {
    enum ImpactStyle {
        case light, medium, heavy, soft, rigid
    }

    enum NotificationType {
        case success, warning, error
    }

    static func impact(_ style: ImpactStyle = .medium) {}

    static func notification(_ type: NotificationType) {}

    static func selection() {}
}
#else
enum HapticManager {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
#endif

