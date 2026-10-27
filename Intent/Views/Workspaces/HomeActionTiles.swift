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
    @Environment(\.workspaceUsesVerticalBar) private var usesVerticalBar
    @State private var availableWidth: CGFloat = 0
    @State private var carouselContentHeight: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.legibilityWeight) private var legibilityWeight
    @ScaledMetric(relativeTo: .body) private var tileHeight = Layout.minimumHeight
    @ScaledMetric(relativeTo: .body) private var titleTracking: CGFloat = -0.32
    @ScaledMetric(relativeTo: .body) private var titleSize = Constants.Typography.bodySEmphasized.size

    nonisolated private enum Layout {
        static let inset: CGFloat = 24
        static let spacing: CGFloat = 8
        static let maximumTileWidth: CGFloat = 192
        static let minimumFittedTileWidth: CGFloat = 152
        static let minimumHeight: CGFloat = 240
        static let wrappedHeight: CGFloat = 144
        static let maximumHeightFraction: CGFloat = 0.75
        static let cornerRadius: CGFloat = 20
        static let iconSize: CGFloat = 24
        static let iconOpacity = 0.3
        static let badgeInset: CGFloat = 2
        static let badgeBorderWidth: CGFloat = 2
        static let badgeClearance: CGFloat = 2
    }

    var body: some View {
        Group {
            if sizeClass == .compact || usesVerticalBar {
                carousel
            } else {
                wrappedTiles
            }
        }
        .accessibilityIdentifier("intent.menu.tiles")
    }

    /// Large text can make cards taller than a short landscape window, so the
    /// viewport is capped like the wrapped grid and scrolls vertically when needed.
    private var carousel: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: Layout.spacing) {
                ForEach(actions, id: \.self) { action in
                    tile(action, height: tileHeight, fillsHeight: true)
                        .frame(width: carouselTileWidth)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Layout.inset)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { carouselContentHeight = $0 }
        }
        .scrollIndicators(.hidden, axes: .horizontal)
        .scrollBounceBehavior(.basedOnSize, axes: [.horizontal, .vertical])
        .containerRelativeFrame(.vertical) { containerHeight, _ in
            Self.carouselHeight(content: max(tileHeight, carouselContentHeight), container: containerHeight)
        }
        .onGeometryChange(for: CGFloat.self) { geometry in
            max(0, geometry.size.width - 2 * Layout.inset)
        } action: { availableWidth = $0 }
    }

    /// Accessibility text gets one card per viewport so titles wrap at word boundaries.
    private var carouselTileWidth: CGFloat {
        Self.carouselTileWidth(in: availableWidth, accessibility: dynamicTypeSize.isAccessibilitySize)
    }

    static func carouselTileWidth(in width: CGFloat, accessibility: Bool) -> CGFloat {
        accessibility ? max(Layout.maximumTileWidth, width) : Layout.maximumTileWidth
    }

    static func carouselHeight(content: CGFloat, container: CGFloat) -> CGFloat {
        min(content, container * Layout.maximumHeightFraction)
    }

    private var wrappedTiles: some View {
        let columns = Self.columnCount(in: availableWidth, actionCount: actions.count, accessibility: dynamicTypeSize.isAccessibilitySize)
        let width = Self.tileWidth(in: availableWidth, actionCount: actions.count, accessibility: dynamicTypeSize.isAccessibilitySize)
        let rows = max(1, (actions.count + columns - 1) / columns)
        let height = rows == 1 ? tileHeight : tileHeight * Layout.wrappedHeight / Layout.minimumHeight
        return ScrollView(.vertical) {
            Grid(horizontalSpacing: Layout.spacing, verticalSpacing: Layout.spacing) {
                ForEach(0..<rows, id: \.self) { row in
                    GridRow {
                        ForEach(actions.dropFirst(row * columns).prefix(columns), id: \.self) { action in
                            tile(action, height: height)
                                .frame(width: width)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, Layout.inset)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .containerRelativeFrame(.vertical) { containerHeight, _ in
            min(CGFloat(rows) * height + CGFloat(rows - 1) * Layout.spacing, containerHeight * Layout.maximumHeightFraction)
        }
        .onGeometryChange(for: CGFloat.self) { geometry in
            max(0, geometry.size.width - 2 * Layout.inset)
        } action: { availableWidth = $0 }
    }

    private var actions: [Action] {
        Action.allCases.filter { action in
            (action != .workspace || allowsWorkspaceCreation) && (action != .assistant || allowsAssistant)
                && (action != .workspaces || showsWorkspaceList)
        }
    }

    static func tileWidth(in width: CGFloat, actionCount: Int, accessibility: Bool) -> CGFloat {
        let columns = CGFloat(columnCount(in: width, actionCount: actionCount, accessibility: accessibility))
        let fittedWidth = max(0, (width - Layout.spacing * (columns - 1)) / columns)
        return accessibility ? fittedWidth : min(Layout.maximumTileWidth, fittedWidth)
    }

    static func columnCount(in width: CGFloat, actionCount: Int, accessibility: Bool) -> Int {
        guard !accessibility else { return 1 }
        let columns = Int(max(0, width + Layout.spacing) / (Layout.minimumFittedTileWidth + Layout.spacing))
        return max(1, min(actionCount, columns))
    }

    private func tile(_ action: Action, height: CGFloat, fillsHeight: Bool = false) -> some View {
        Button { onSelect(action) } label: {
            VStack(alignment: .leading) {
                icon(action)
                    .frame(width: Layout.iconSize, height: Layout.iconSize)
                    .accessibilityHidden(true)
                Spacer(minLength: Layout.inset)
                tileTitle(action)
            }
            .padding(Layout.inset)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: fillsHeight ? .infinity : nil, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .circular))
            .homeActionTileSurface(cornerRadius: Layout.cornerRadius, fill: Constants.WorkspaceList.controlSurface(for: colorScheme))
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
