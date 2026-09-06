import Testing
import UIKit
@testable import Intent

/// HapticManager keeps the same call-site API on every platform (no-op bodies
/// on visionOS, UIFeedbackGenerator elsewhere); exercising every entry point
/// must be safe regardless of haptics hardware.
struct HapticManagerTests {
    @Test func impactIsSafeForEveryStyle() {
        HapticManager.impact()
        HapticManager.impact(.light)
        HapticManager.impact(.medium)
        HapticManager.impact(.heavy)
        HapticManager.impact(.soft)
        HapticManager.impact(.rigid)
    }

    @Test func notificationIsSafeForEveryType() {
        HapticManager.notification(.success)
        HapticManager.notification(.warning)
        HapticManager.notification(.error)
    }

    @Test func selectionIsSafe() {
        HapticManager.selection()
    }
}
