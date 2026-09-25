import Combine
import SwiftUI
import UIKit

/// Publishes the backend label through this view's own scene. Kept outside
/// navigation and session identities so Home/rebinds update the same anchor.
struct WindowSceneTitle: UIViewRepresentable {
    let title: String?

    func makeUIView(context _: Context) -> TitleView {
        let view = TitleView()
        view.isUserInteractionEnabled = false
        view.title = title
        return view
    }

    func updateUIView(_ view: TitleView, context _: Context) {
        view.title = title
    }

    static func dismantleUIView(_ view: TitleView, coordinator _: Void) {
        view.detach()
    }

    final class TitleView: UIView {
        var title: String? {
            didSet {
                observeTitle()
                applyTitle()
            }
        }
        private weak var scene: UIWindowScene?
        private var titleObservation: AnyCancellable?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Transient removal need not erase the last published title;
            // reattachment publishes the latest value to the new scene.
            titleObservation = nil
            scene = window?.windowScene
            observeTitle()
            applyTitle()
        }

        private func observeTitle() {
            titleObservation = nil
            guard title != nil, let scene else { return }
            // SwiftUI reflects primary navigation titles into UIScene.title.
            // Reassert the server label after those writes, leaving in-app
            // navigation titles untouched. Equality prevents feedback loops.
            titleObservation = scene.publisher(for: \.title, options: [.new])
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.applyTitle() }
        }

        private func applyTitle() {
            guard let scene, scene.title != (title ?? "") else { return }
            scene.title = title ?? ""
        }

        func detach() {
            titleObservation = nil
            if scene?.title == (title ?? "") { scene?.title = "" }
            scene = nil
        }
    }
}
