import CoreText
import SwiftUI

struct HomeActionTiles: View {
    enum Action: String, CaseIterable {
        case assistant
        case workspaces
        case workspace
        case connections
        case appearance
        case settings
    }

    let connectionCount: Int
    let appearance: String
    let themePreference: String
    let onSelect: (Action) -> Void
    var allowsWorkspaceCreation = true
    var allowsAssistant = true
    var showsWorkspaceList = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.legibilityWeight) private var legibilityWeight
    @ScaledMetric(relativeTo: .body) private var tileHeight = Layout.minimumHeight
    @ScaledMetric(relativeTo: .body) private var titleTracking: CGFloat = -0.32
    @ScaledMetric(relativeTo: .body) private var titleSize = Constants.Typography.bodySEmphasized.size

    nonisolated private enum Layout {
        static let inset: CGFloat = 24
        static let spacing: CGFloat = 8
        static let maximumTileWidth: CGFloat = 192
        static let minimumTileWidth: CGFloat = 160
        static let minimumHeight: CGFloat = 240
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
                        && (action != .workspaces || showsWorkspaceList)
                }, id: \.self) { action in
                    tile(action)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .scrollTargetBehavior(.viewAligned)
        .defaultScrollAnchor(.trailing, for: .alignment)
        .contentMargins(.horizontal, sizeClass == .regular ? 0 : Layout.inset, for: .scrollContent)
        .padding(.horizontal, sizeClass == .regular ? Layout.inset : 0)
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
            .frame(maxWidth: .infinity, minHeight: max(Layout.minimumHeight, tileHeight), alignment: .leading)
            .containerRelativeFrame(.horizontal) { width, _ in
                let columns: CGFloat = dynamicTypeSize.isAccessibilitySize ? 1 : 2
                let contentWidth = min(width, Layout.maximumTileWidth * 2 + Layout.spacing)
                return max(Layout.minimumTileWidth, (contentWidth - Layout.spacing * (columns - 1)) / columns)
            }
            .background(Constants.WorkspaceList.controlSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .circular))
            .contentShape(RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .circular))
        }
        .buttonStyle(HomeActionTileStyle())
        .accessibilityLabel(action == .appearance ? "Appearance" : title(action))
        .accessibilityValue(action == .appearance ? appearance : "")
        .accessibilityHint(action == .appearance ? "Changes appearance" : "")
        .accessibilityIdentifier("intent.menu.\(action.rawValue)")
    }

    private func tileTitle(_ action: Action) -> some View {
        let style = Constants.Typography.bodySEmphasized
        let face = legibilityWeight == .bold ? style.face.legibleFace : style.face
        let font = CTFontCreateWithName(face.rawValue as CFString, titleSize, nil)
        let capHeight = CTFontGetCapHeight(font)
        return VStack(alignment: .leading, spacing: titleSize - capHeight) {
            ForEach(title(action).components(separatedBy: "\n"), id: \.self) { line in
                WorkspaceTextTrimLayout(capHeight: capHeight) {
                    Text(line)
                        .interFont(style)
                        .tracking(titleTracking)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(Constants.Pairing.foreground(for: colorScheme))
                }
            }
        }
        .accessibilityElement(children: .combine)
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
        case .workspaces: "Workspaces"
        case .workspace: "New\nWorkspace"
        case .connections: "Connections:\n\(connectionCount) \(connectionCount == 1 ? "Device" : "Devices")"
        case .appearance: "Appearance:\n\(appearance)"
        case .settings: "Settings"
        }
    }

    private func asset(_ action: Action) -> ImageResource {
        switch action {
        case .assistant: .intentDandelion
        case .workspaces: .agentGeneral1
        case .workspace: .addIcon
        case .connections: .connectionLaptop
        case .appearance:
            switch themePreference {
            case "light": .brightnessFull
            case "dark": .night
            default: .brightnessRise
            }
        case .settings: .settings2
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
