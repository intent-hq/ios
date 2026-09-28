import SwiftUI
import UIKit

struct NavigationPopObserver: UIViewControllerRepresentable {
    @Binding var isPopping: Bool

    func makeUIViewController(context _: Context) -> Controller {
        let controller = Controller()
        controller.isPopping = $isPopping
        return controller
    }

    func updateUIViewController(_ controller: Controller, context _: Context) {
        controller.isPopping = $isPopping
    }

    final class Controller: UIViewController {
        var isPopping = Binding.constant(false)

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            // UIKit also calls this when an interactive pop is cancelled.
            if isPopping.wrappedValue { isPopping.wrappedValue = false }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            guard let navigationController else { return }
            var destination: UIViewController = self
            while let parent = destination.parent, parent !== navigationController {
                destination = parent
            }
            if !navigationController.viewControllers.contains(where: { $0 === destination }) {
                isPopping.wrappedValue = true
            }
        }
    }
}
