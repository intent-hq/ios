import Combine
import SwiftUI
import UIKit

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
            titleObservation = nil
            scene = window?.windowScene
            observeTitle()
            applyTitle()
        }

        private func observeTitle() {
            titleObservation = nil
            guard title != nil, let scene else { return }
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
