import SwiftUI
import UIKit

enum UITestAnimations {
    static let environmentKey = "INTENT_UI_TEST_ANIMATIONS"
    static let disabled = isDisabled(by: LaunchOptions.current)
    static let layerSpeed: Float = 100

    nonisolated static func isDisabled(by options: LaunchOptions) -> Bool {
        #if DEBUG
        options.environment[environmentKey] == "off"
        #else
        false
        #endif
    }

    static func speedUpConnectedWindows() {
        UIView.setAnimationsEnabled(false)
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.layer.speed = layerSpeed
            }
        }
    }
}

extension View {
    @ViewBuilder
    func uiTestAnimations() -> some View {
        if UITestAnimations.disabled {
            transaction { transaction in
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
            .onAppear(perform: UITestAnimations.speedUpConnectedWindows)
            .onReceive(NotificationCenter.default.publisher(for: UIWindow.didBecomeVisibleNotification)) { notification in
                (notification.object as? UIWindow)?.layer.speed = UITestAnimations.layerSpeed
            }
        } else {
            self
        }
    }
}
