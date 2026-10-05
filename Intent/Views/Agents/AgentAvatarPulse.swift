import SwiftUI
import UIKit

/// A render-server pulse with no per-frame SwiftUI updates.
struct AgentAvatarPulse: UIViewRepresentable {
    let cornerRadius: CGFloat

    func makeUIView(context _: Context) -> PulseView {
        PulseView(cornerRadius: cornerRadius)
    }

    func updateUIView(_ view: PulseView, context _: Context) {
        view.cornerRadius = cornerRadius
        view.updatePulse()
    }

    final class PulseView: UIView {
        private static let animationKey = "agentAvatarPulse"
        // PhaseAnimator held each endpoint for 50 ms on the 60 Hz reference recording.
        private static let endpointHoldDuration: CFTimeInterval = 0.05
        private let ring = CAShapeLayer()
        var cornerRadius: CGFloat {
            didSet {
                if oldValue != cornerRadius { setNeedsLayout() }
            }
        }

        init(cornerRadius: CGFloat) {
            self.cornerRadius = cornerRadius
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            ring.fillColor = nil
            ring.lineWidth = Constants.AgentAvatar.activeStrokeWidth
            layer.addSublayer(ring)
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _: UITraitCollection) in
                view.updatePulse()
            }
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.frame = bounds
            // Reuse SwiftUI's continuous path, including its centered stroke.
            ring.path = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .path(in: CGRect(origin: .zero, size: bounds.size)).cgPath
            CATransaction.commit()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
            guard window != nil else {
                ring.removeAnimation(forKey: Self.animationKey)
                return
            }
            NotificationCenter.default.addObserver(
                self, selector: #selector(updatePulse), name: UIApplication.didBecomeActiveNotification, object: nil
            )
            updatePulse()
        }

        /// UIKit delivers activation on the main thread. Reinstall if backgrounding
        /// removed the animation, but don't restart a running pulse on view updates.
        @objc func updatePulse() {
            let weakColor = UIColor(Constants.Colors.AgentAvatar.activeStrokeWeak)
                .resolvedColor(with: traitCollection).cgColor
            let strongColor = UIColor(Constants.Colors.AgentAvatar.activeStrokeStrong)
                .resolvedColor(with: traitCollection).cgColor
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.strokeColor = weakColor
            CATransaction.commit()
            guard window != nil else { return }
            if let current = ring.animation(forKey: Self.animationKey) as? CAKeyframeAnimation,
               let colors = current.values, colors.count >= 2,
               CFEqual(colors[0] as CFTypeRef, weakColor), CFEqual(colors[1] as CFTypeRef, strongColor) {
                return
            }
            let transition = Constants.AgentAvatar.pulseAnimationDuration
            let hold = Self.endpointHoldDuration
            let duration = 2 * (transition + hold)
            let pulse = CAKeyframeAnimation(keyPath: "strokeColor")
            pulse.values = [weakColor, strongColor, strongColor, weakColor, weakColor]
            pulse.keyTimes = [
                0, transition / duration, (transition + hold) / duration,
                (2 * transition + hold) / duration, 1
            ].map { .init(value: $0) }
            pulse.duration = duration
            pulse.calculationMode = .linear
            pulse.timingFunctions = [
                CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .linear),
                CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .linear)
            ]
            pulse.repeatCount = .infinity
            ring.add(pulse, forKey: Self.animationKey)
        }
    }
}
