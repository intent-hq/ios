import SwiftUI
import UIKit

struct WorkspaceTitle<Content: View>: View {
    let title: String
    var placeholderSize: CGFloat = Constants.Typography.bodyM.size
    @ViewBuilder let content: (String) -> Content

    var body: some View {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            WorkspaceTitlePlaceholder(size: placeholderSize)
        } else {
            content(title)
        }
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
        .accessibilityLabel("New workspace")
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
