import SwiftUI

struct HomeActionTiles: View {
    enum Action: String, CaseIterable {
        case assistant
        case workspace
        case connections
        case appearance
        case acknowledgements
        case logOff
    }

    let connectionCount: Int
    let appearance: String
    let onSelect: (Action) -> Void
    let onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var tileWidth: CGFloat = 172
    @ScaledMetric(relativeTo: .body) private var tileHeight: CGFloat = 240

    private enum Layout {
        static let inset: CGFloat = 24
        static let spacing: CGFloat = 8
        static let footerSpacing: CGFloat = 20
        static let bottomInset: CGFloat = 12
        static let cornerRadius: CGFloat = 20
        static let iconSize: CGFloat = 22
        static let closeSize: CGFloat = 48
        static let badgeInset: CGFloat = 2
        static let pressedOpacity = 0.7
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: Layout.footerSpacing) {
            ScrollView(.horizontal) {
                HStack(spacing: Layout.spacing) {
                    ForEach(Action.allCases, id: \.self) { action in
                        tile(action)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, Layout.inset, for: .scrollContent)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("intent.menu.tiles")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.title3)
                    .foregroundStyle(.black)
                    .accessibilityHidden(true)
                    .frame(width: Layout.closeSize, height: Layout.closeSize)
                    .background(Color(.assistantAccent), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Intent menu")
            .accessibilityIdentifier("intent.menu.close")
            .padding(.trailing, Layout.inset)
        }
        .padding(.bottom, Layout.bottomInset)
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
            Image(systemName: symbol(action))
                .font(.title3)
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
        case .logOff: "Log Off"
        }
    }

    private func symbol(_ action: Action) -> String {
        switch action {
        case .assistant: "bubble.left"
        case .workspace: "plus"
        case .connections: "desktopcomputer"
        case .appearance: "moon"
        case .acknowledgements: "doc.text"
        case .logOff: "rectangle.portrait.and.arrow.right"
        }
    }

    private struct HomeActionTileStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.opacity(configuration.isPressed ? Layout.pressedOpacity : 1)
        }
    }
}
