import SwiftUI

/// Native sheet chrome shared by the connection destinations. The detent follows
/// measured content, while the system limits tall sheets and manages the keyboard.
struct ConnectionSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var contentHeight: CGFloat = 0
    let initialHeight: CGFloat
    var backgroundColor: Color?
    var closeForeground: Color?
    @ViewBuilder let content: Content

    var body: some View {
        // Safe-area-aware bottom breathing room, including on home-button devices.
        // swiftlint:disable:next geometry_reader_usage
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                Button { dismiss() } label: {
                    Image(.connectionClose)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: Constants.ConnectionSheet.glyphSize, height: Constants.ConnectionSheet.glyphSize)
                        .frame(width: Constants.ConnectionSheet.closeSize, height: Constants.ConnectionSheet.closeSize)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(closeForeground ?? Constants.Pairing.foreground(for: colorScheme))
                .accessibilityLabel("Close")
                .accessibilityIdentifier("connection-sheet.close")
                .padding(.horizontal, Constants.ConnectionSheet.inset)
                .padding(.top, Constants.ConnectionSheet.inset)

                ScrollView {
                    content
                        .padding(.top, Constants.ConnectionSheet.headerGap)
                        .padding(.horizontal, Constants.ConnectionSheet.inset)
                        .padding(.bottom, max(
                            Constants.ConnectionSheet.minimumBottomPadding,
                            Constants.ConnectionSheet.bottomSpacing - geometry.safeAreaInsets.bottom
                        ))
                        .frame(maxWidth: .infinity)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .background(backgroundColor ?? Constants.Pairing.background(for: colorScheme))
        .presentationBackground(backgroundColor ?? Constants.Pairing.background(for: colorScheme))
        .presentationCornerRadius(Constants.ConnectionSheet.cornerRadius)
        .presentationDragIndicator(.hidden)
        .presentationDetents([
            .height(contentHeight > 0
                ? contentHeight + Constants.ConnectionSheet.closeSize + Constants.ConnectionSheet.inset
                : initialHeight)
        ])
    }
}
