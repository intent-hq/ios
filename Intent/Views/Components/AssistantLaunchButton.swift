import SwiftUI

struct AssistantLaunchButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Layout {
        static let closeCornerRadius: CGFloat = 20
        static let iconSize: CGFloat = 22
        static let closeIconSize: CGFloat = 24
        static let iconRotation = 90.0
        static let hiddenIconScale = 0.6
        static let shadowRadius: CGFloat = 20
        static let shadowOffset: CGFloat = 10
        static let shadowOpacity = 0.08
    }

    static let scrollClearance = AssistantLauncherLayout.current.scrollClearance
    let isOpen: Bool
    var isInVerticalBar = false
    var layout = AssistantLauncherLayout.current
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            icon
                .foregroundStyle(.black)
                .accessibilityHidden(true)
                .frame(width: size, height: size)
                .background(Color(.assistantAccent), in: shape)
                .contentShape(shape)
        }
        .buttonStyle(IntentContentButtonStyle())
        .frame(width: size, height: size)
        .shadow(
            color: .black.opacity(isOpen || isInVerticalBar ? 0 : Layout.shadowOpacity),
            radius: Layout.shadowRadius,
            y: Layout.shadowOffset
        )
        .accessibilityLabel(isOpen ? "Close Intent menu" : "Intent menu")
        .accessibilityIdentifier(isOpen ? "intent.menu.close" : "intent.menu.open")
        .keepsReadOnlyPillAbove()
        .padding(.horizontal, isInVerticalBar ? 0 : layout.horizontalInset)
    }

    private var size: CGFloat { isOpen || isInVerticalBar ? layout.closeSize : layout.diameter }

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: isOpen || isInVerticalBar ? Layout.closeCornerRadius : layout.diameter / 2,
            style: isOpen || isInVerticalBar ? .circular : .continuous
        )
    }

    private var icon: some View {
        ZStack {
            Image(.intentDandelion)
                .resizable()
                .scaledToFit()
                .rotationEffect(.degrees(isOpen && !reduceMotion ? Layout.iconRotation : 0))
                .scaleEffect(isOpen && !reduceMotion ? Layout.hiddenIconScale : 1)
                .opacity(isOpen ? 0 : 1)
                .accessibilityHidden(true)
            Image(.close)
                .resizable()
                .scaledToFit()
                .rotationEffect(.degrees(isOpen || reduceMotion ? 0 : -Layout.iconRotation))
                .scaleEffect(isOpen || reduceMotion ? 1 : Layout.hiddenIconScale)
                .opacity(isOpen ? 1 : 0)
                .accessibilityHidden(true)
        }
        .frame(width: isOpen ? Layout.closeIconSize : Layout.iconSize, height: isOpen ? Layout.closeIconSize : Layout.iconSize)
    }
}

/// Keep the visible control, hit shape, menu anchor and scroll clearance together.
struct AssistantLauncherLayout {
    let diameter: CGFloat
    let closeSize: CGFloat
    let horizontalInset: CGFloat
    let launcherBottomInset: CGFloat
    let menuBottomInset: CGFloat
    let tileExtraInset: CGFloat

    // Named layout presets keep platform geometry in one place.
    private enum Handheld {
        static let diameter: CGFloat = 80
        static let closeSize: CGFloat = 48
        static let horizontalInset: CGFloat = 24
        static let launcherBottomInset: CGFloat = 12
        static let menuBottomInset: CGFloat = 24
        static let tileExtraInset: CGFloat = 0
    }

    private enum Spatial {
        static let diameter: CGFloat = 88
        static let closeSize: CGFloat = 60
        static let horizontalInset: CGFloat = 48
        static let launcherBottomInset: CGFloat = 36
        static let menuBottomInset: CGFloat = 48
        static let tileExtraInset: CGFloat = 24
    }

    static let handheld = Self(
        diameter: Handheld.diameter,
        closeSize: Handheld.closeSize,
        horizontalInset: Handheld.horizontalInset,
        launcherBottomInset: Handheld.launcherBottomInset,
        menuBottomInset: Handheld.menuBottomInset,
        tileExtraInset: Handheld.tileExtraInset
    )
    static let spatial = Self(
        diameter: Spatial.diameter,
        closeSize: Spatial.closeSize,
        horizontalInset: Spatial.horizontalInset,
        launcherBottomInset: Spatial.launcherBottomInset,
        menuBottomInset: Spatial.menuBottomInset,
        tileExtraInset: Spatial.tileExtraInset
    )

    static var current: Self {
        #if os(visionOS)
        spatial
        #else
        handheld
        #endif
    }

    var scrollClearance: CGFloat {
        // Leave breathing room above the tallest control in either state.
        let contentGap: CGFloat = 12
        return max(diameter + launcherBottomInset, closeSize + menuBottomInset) + contentGap
    }
}
