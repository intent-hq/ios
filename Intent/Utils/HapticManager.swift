import UIKit

#if os(visionOS)
enum HapticManager {
    enum ImpactStyle {
        case heavy, light, medium, rigid, soft
    }

    enum NotificationType {
        case error, success, warning
    }

    static func impact(_: ImpactStyle = .medium) {}

    static func notification(_: NotificationType) {}

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
