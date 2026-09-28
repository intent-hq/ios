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
    let onSelect: (Action) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var tileWidth: CGFloat = 172
    @ScaledMetric(relativeTo: .body) private var tileHeight: CGFloat = 240

    private enum Layout {
        static let inset: CGFloat = 24
        static let spacing: CGFloat = 8
        static let cornerRadius: CGFloat = 20
        static let iconSize: CGFloat = 22
        static let badgeInset: CGFloat = 2
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Layout.spacing) {
                ForEach(Action.allCases, id: \.self) { action in
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
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .frame(width: Layout.iconSize, height: Layout.iconSize)
                    .accessibilityHidden(true)
                Spacer(minLength: Layout.inset)
                Text(title(action))
                    .font(Constants.Typography.bodySEmphasized.font)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
            }
            .padding(Layout.inset)
            .frame(width: tileWidth, height: tileHeight, alignment: .leading)
            .background(Constants.Pairing.surface(for: colorScheme), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: Layout.cornerRadius))
        }
        .buttonStyle(HomeActionTileStyle())
        .accessibilityIdentifier("intent.menu.\(action.rawValue)")
    }

    @ViewBuilder private func icon(_ action: Action) -> some View {
        if action == .assistant {
            Image(.intentDandelion).resizable().scaledToFit().accessibilityHidden(true)
        } else {
            Image(asset(action))
                .resizable()
                .scaledToFit()
                .overlay(alignment: .topTrailing) {
                    if action == .connections, connectionCount > 0 {
                        Text(connectionCount.formatted())
                            .font(.caption2.bold())
                            .foregroundStyle(.black)
                            .padding(Layout.badgeInset)
                            .background(Color(.assistantAccent), in: Capsule())
                            .alignmentGuide(.top) { $0.height / 2 }
                            .alignmentGuide(.trailing) { $0.width / 2 }
                    }
                }
                .accessibilityHidden(true)
        }
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
        case .appearance: .night
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
