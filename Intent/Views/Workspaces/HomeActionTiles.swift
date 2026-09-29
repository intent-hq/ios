import CoreText
import SwiftUI

struct HomeActionTiles: View {
    enum Action: String, CaseIterable {
        case assistant
        case workspace
        case connections
        case appearance
        case acknowledgements
        case settings
        case logOff
    }

    let connectionCount: Int
    let appearance: String
    let themePreference: String
    let onSelect: (Action) -> Void
    var allowsWorkspaceCreation = true
    var allowsAssistant = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.legibilityWeight) private var legibilityWeight
    @ScaledMetric(relativeTo: .body) private var tileHeight: CGFloat = 240
    @ScaledMetric(relativeTo: .headline) private var titleTracking: CGFloat = -0.36
    @ScaledMetric(relativeTo: .headline) private var titleSize = Constants.Typography.bodyM.size

    private enum Layout {
        static let inset: CGFloat = 24
        static let spacing: CGFloat = 8
        static let cornerRadius: CGFloat = 20
        static let iconSize: CGFloat = 24
        static let iconOpacity = 0.3
        static let badgeInset: CGFloat = 2
        static let badgeBorderWidth: CGFloat = 2
        static let badgeClearance: CGFloat = 2
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Layout.spacing) {
                ForEach(Action.allCases.filter { action in
                    (action != .workspace || allowsWorkspaceCreation) && (action != .assistant || allowsAssistant)
                }, id: \.self) { action in
                    tile(action)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, Layout.inset, for: .scrollContent)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("intent.menu.tiles")
    }

    private func tile(_ action: Action) -> some View {
        Button { onSelect(action) } label: {
            VStack(alignment: .leading) {
                icon(action)
                    .frame(width: Layout.iconSize, height: Layout.iconSize)
                    .accessibilityHidden(true)
                Spacer(minLength: Layout.inset)
                tileTitle(action)
            }
            .padding(Layout.inset)
            .frame(maxWidth: .infinity, minHeight: tileHeight, alignment: .leading)
            .containerRelativeFrame(.horizontal, count: dynamicTypeSize.isAccessibilitySize ? 1 : 2, spacing: Layout.spacing)
            .background(Constants.WorkspaceList.controlSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: Layout.cornerRadius))
        }
        .buttonStyle(HomeActionTileStyle())
        .accessibilityLabel(action == .appearance ? "Appearance" : title(action))
        .accessibilityValue(action == .appearance ? appearance : "")
        .accessibilityHint(action == .appearance ? "Changes appearance" : "")
        .accessibilityIdentifier("intent.menu.\(action.rawValue)")
    }

    private func tileTitle(_ action: Action) -> some View {
        let style = Constants.Typography.bodyM
        let face = legibilityWeight == .bold ? style.face.legibleFace : style.face
        let font = CTFontCreateWithName(face.rawValue as CFString, titleSize, nil)
        let lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        return WorkspaceTextTrimLayout(capHeight: CTFontGetCapHeight(font)) {
            Text(title(action))
                .interFont(style)
                .tracking(titleTracking)
                .lineSpacing(titleSize - lineHeight)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(Constants.Pairing.foreground(for: colorScheme))
        }
    }

    @ViewBuilder private func icon(_ action: Action) -> some View {
        if action == .assistant {
            Image(.intentDandelion)
                .resizable()
                .scaledToFit()
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)
        } else {
            Image(asset(action))
                .resizable()
                .scaledToFit()
                .foregroundStyle(iconColor)
                .overlay(alignment: .topTrailing) {
                    if action == .connections, connectionCount > 0 {
                        Text(connectionCount.formatted())
                            .font(.caption2.bold())
                            .foregroundStyle(.black)
                            .padding(Layout.badgeInset)
                            .background(Color(.assistantAccent), in: Capsule())
                            .overlay {
                                Capsule()
                                    .stroke(Constants.WorkspaceList.controlSurface(for: colorScheme), lineWidth: Layout.badgeBorderWidth)
                                    .padding(-Layout.badgeBorderWidth / 2)
                            }
                            .alignmentGuide(.top) { $0.height / 2 + Layout.badgeClearance }
                            .alignmentGuide(.trailing) { $0.width / 2 - Layout.badgeClearance }
                    }
                }
                .accessibilityHidden(true)
        }
    }

    private var iconColor: Color {
        (colorScheme == .dark ? Color.white : Constants.Pairing.foreground(for: colorScheme)).opacity(Layout.iconOpacity)
    }

    private func title(_ action: Action) -> String {
        switch action {
        case .assistant: "Chat With\nAssistant"
        case .workspace: "New\nWorkspace"
        case .connections: "Connections:\n\(connectionCount) \(connectionCount == 1 ? "Device" : "Devices")"
        case .appearance: "Appearance:\n\(appearance)"
        case .acknowledgements: "Acks &\nLogs"
        case .settings: "Settings"
        case .logOff: "Log Off"
        }
    }

    private func asset(_ action: Action) -> ImageResource {
        switch action {
        case .assistant: .intentDandelion
        case .workspace: .addIcon
        case .connections: .connectionLaptop
        case .appearance:
            switch themePreference {
            case "light": .brightnessFull
            case "dark": .night
            default: .brightnessRise
            }
        case .acknowledgements: .file
        case .settings: .settings2
        case .logOff: .logout
        }
    }

    private struct HomeActionTileStyle: PrimitiveButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .onTapGesture { configuration.trigger() }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { configuration.trigger() }
        }
    }
}
