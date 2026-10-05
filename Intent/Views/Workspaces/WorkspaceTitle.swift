import SwiftUI
import UIKit

struct WorkspaceTitle<Content: View>: View {
    let title: String
    let createdAt: String?
    @ViewBuilder let content: (String) -> Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content("New Workspace")
                .foregroundStyle(Theme.mutedForeground(for: colorScheme, contrast: contrast))
                .mask {
                    WorkspaceTitleShimmer(
                        createdAt: createdAt,
                        isAnimating: !reduceMotion && scenePhase == .active && contrast != .increased,
                        highContrast: contrast == .increased
                    )
                }
        } else {
            content(title)
        }
    }
}

struct WorkspaceTitleShimmerLifetime {
    private static let timeout: TimeInterval = 60
    let deadline: Date

    init(createdAt: String?, firstShownAt: Date) {
        let created = ISO8601DateFormatter.lenientDate(from: createdAt) ?? firstShownAt
        deadline = min(created, firstShownAt).addingTimeInterval(Self.timeout)
    }

    func remaining(at now: Date) -> TimeInterval {
        max(0, deadline.timeIntervalSince(now))
    }
}

private struct WorkspaceTitleShimmer: UIViewRepresentable {
    let createdAt: String?
    let isAnimating: Bool
    let highContrast: Bool

    func makeUIView(context _: Context) -> WorkspaceTitleShimmerView {
        WorkspaceTitleShimmerView()
    }

    func updateUIView(_ view: WorkspaceTitleShimmerView, context _: Context) {
        view.configure(createdAt: createdAt, isAnimating: isAnimating, highContrast: highContrast)
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
    private let firstShownAt = Date()
    private var lifetime: WorkspaceTitleShimmerLifetime?
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

    func configure(createdAt: String?, isAnimating: Bool, highContrast: Bool) {
        let lifetime = WorkspaceTitleShimmerLifetime(createdAt: createdAt, firstShownAt: firstShownAt)
        if self.lifetime?.deadline != lifetime.deadline {
            gradient.removeAnimation(forKey: Self.animationKey)
        }
        self.lifetime = lifetime
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
        let remaining = lifetime?.remaining(at: Date()) ?? 0
        guard isAnimating, window != nil, !bounds.isEmpty, remaining > 0 else {
            gradient.removeAnimation(forKey: Self.animationKey)
            return
        }
        guard gradient.animation(forKey: Self.animationKey) == nil else { return }
        let shimmer = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shimmer.values = [-bounds.width, bounds.width, bounds.width]
        shimmer.keyTimes = [0, Self.sweepEnd, 1].map { .init(value: $0) }
        shimmer.duration = Self.shimmerDuration
        shimmer.repeatDuration = remaining
        gradient.add(shimmer, forKey: Self.animationKey)
    }
}
