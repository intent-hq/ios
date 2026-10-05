import SwiftUI
import UIKit

struct WorkspaceTitle<Content: View>: View {
    let title: String
    var rollingPlaceholderSize: CGFloat?
    @ViewBuilder let content: (String) -> Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let rollingPlaceholderSize {
                WorkspaceTitlePlaceholder(size: rollingPlaceholderSize)
            } else {
                content("New Workspace")
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme, contrast: contrast))
                    .mask {
                        WorkspaceTitleShimmer(
                            isAnimating: !reduceMotion && scenePhase == .active && contrast != .increased,
                            highContrast: contrast == .increased
                        )
                    }
            }
        } else {
            content(title)
        }
    }
}

private struct WorkspaceTitleShimmer: UIViewRepresentable {
    let isAnimating: Bool
    let highContrast: Bool

    func makeUIView(context _: Context) -> WorkspaceTitleShimmerView {
        WorkspaceTitleShimmerView()
    }

    func updateUIView(_ view: WorkspaceTitleShimmerView, context _: Context) {
        view.configure(isAnimating: isAnimating, highContrast: highContrast)
    }
}

private final class WorkspaceTitleShimmerView: UIView {
    private static let animationKey = "workspaceTitleShimmer"
    private static let shimmerDuration: CFTimeInterval = 4
    private static let baseOpacity: CGFloat = 0.62
    private static let peakOpacity: CGFloat = 0.85
    private static let sweepEnd = 0.8
    private static let gradientWidthMultiplier: CGFloat = 3
    private let gradient = CAGradientLayer()
    private var isAnimating = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.locations = [
            1 / Double(Self.gradientWidthMultiplier),
            0.5,
            2 / Double(Self.gradientWidthMultiplier)
        ].map { .init(value: $0) }
        layer.addSublayer(gradient)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(isAnimating: Bool, highContrast: Bool) {
        self.isAnimating = isAnimating
        let base = UIColor.white.withAlphaComponent(highContrast ? 1 : Self.baseOpacity).cgColor
        let peak = UIColor.white.withAlphaComponent(highContrast ? 1 : Self.peakOpacity).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.colors = [base, peak, base]
        CATransaction.commit()
        synchronize()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width * Self.gradientWidthMultiplier
        if gradient.bounds.width != width {
            gradient.removeAnimation(forKey: Self.animationKey)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        gradient.transform = CATransform3DMakeTranslation(-bounds.width, 0, 0)
        CATransaction.commit()
        synchronize()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        synchronize()
    }

    private func synchronize() {
        guard isAnimating, window != nil, !bounds.isEmpty else {
            gradient.removeAnimation(forKey: Self.animationKey)
            return
        }
        guard gradient.animation(forKey: Self.animationKey) == nil else { return }
        let shimmer = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shimmer.values = [-bounds.width, bounds.width, bounds.width]
        shimmer.keyTimes = [0, Self.sweepEnd, 1].map { .init(value: $0) }
        shimmer.duration = Self.shimmerDuration
        shimmer.repeatCount = .infinity
        gradient.add(shimmer, forKey: Self.animationKey)
    }
}

private struct WorkspaceTitlePlaceholder: View {
    private static let widthInDiameters: CGFloat = 4
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric private var size: CGFloat

    init(size: CGFloat) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: .headline)
    }

    var body: some View {
        RollingDandelion(
            color: Theme.mutedForeground(for: colorScheme, contrast: contrast),
            isAnimating: !reduceMotion && scenePhase == .active
        )
        .frame(width: size * Self.widthInDiameters, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New Workspace")
        .accessibilityIdentifier("workspace.titlePlaceholder")
    }
}

private struct RollingDandelion: UIViewRepresentable {
    let color: Color
    let isAnimating: Bool

    func makeUIView(context _: Context) -> RollingDandelionView {
        RollingDandelionView()
    }

    func updateUIView(_ view: RollingDandelionView, context _: Context) {
        view.configure(color: UIColor(color), isAnimating: isAnimating)
    }
}

private final class RollingDandelionView: UIView {
    private static let animationKey = "workspaceTitleRoll"
    private static let rollDuration: CFTimeInterval = 2.4
    private let logo = UIImageView(image: UIImage(resource: .intentDandelion))
    private var isAnimating = false
    private var travel: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        logo.contentMode = .scaleAspectFit
        addSubview(logo)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(color: UIColor, isAnimating: Bool) {
        logo.tintColor = color
        self.isAnimating = isAnimating
        synchronize()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let diameter = min(bounds.height, bounds.width)
        let newTravel = max(0, bounds.width - diameter)
        if travel != newTravel || logo.bounds.height != diameter {
            logo.layer.removeAnimation(forKey: Self.animationKey)
        }
        travel = newTravel
        logo.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        logo.center = CGPoint(x: bounds.midX, y: bounds.midY)
        synchronize()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        synchronize()
    }

    private func synchronize() {
        guard isAnimating, window != nil, travel > 0, logo.bounds.height > 0 else {
            logo.layer.removeAnimation(forKey: Self.animationKey)
            return
        }
        guard logo.layer.animation(forKey: Self.animationKey) == nil else { return }

        let translation = CABasicAnimation(keyPath: "transform.translation.x")
        translation.fromValue = -travel / 2
        translation.toValue = travel / 2
        translation.duration = Self.rollDuration
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = -travel / logo.bounds.height
        rotation.toValue = travel / logo.bounds.height
        rotation.duration = Self.rollDuration

        // Matching timing and distance keep the dandelion rolling without sliding.
        let roll = CAAnimationGroup()
        roll.animations = [translation, rotation]
        roll.duration = Self.rollDuration
        roll.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        roll.autoreverses = true
        roll.repeatCount = .infinity
        logo.layer.add(roll, forKey: Self.animationKey)
    }
}
