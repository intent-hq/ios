import UIKit

extension SyntheticBadgeHostTrace {
    func bind(window: UIWindow, controller: UIViewController) {
        captureState = { [weak window, weak controller] in
            guard let window, let controller else { return ["host": "released"] }
            // viewIfLoaded observes attachment without causing UIKit to load or lay out a view.
            let view = controller.viewIfLoaded
            return [
                "window": String(describing: ObjectIdentifier(window)),
                "controller": String(describing: ObjectIdentifier(controller)),
                "scene": window.windowScene?.session.persistentIdentifier ?? "nil",
                "sceneState": window.windowScene.map { String($0.activationState.rawValue) } ?? "nil",
                "applicationState": String(UIApplication.shared.applicationState.rawValue),
                "hidden": String(window.isHidden),
                "keyWindow": String(window.isKeyWindow),
                "rootMatchesController": String(window.rootViewController === controller),
                "viewLoaded": String(controller.isViewLoaded),
                "viewWindow": view?.window.map { String(describing: ObjectIdentifier($0)) } ?? "nil",
                "windowBounds": String(describing: window.bounds),
                "viewBounds": view.map { String(describing: $0.bounds) } ?? "nil"
            ]
        }
    }
}
