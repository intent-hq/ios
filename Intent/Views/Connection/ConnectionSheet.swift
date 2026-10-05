import SwiftUI

/// Native sheet chrome shared by the connection destinations. The detent follows
/// measured content, while the system limits tall sheets and manages the keyboard.
struct ConnectionSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var contentHeight: CGFloat = 0
    @State private var bottomSafeAreaInset: CGFloat = 0
    let initialHeight: CGFloat
    var backgroundColor: Color?
    var closeForeground: Color?
    var isDismissDisabled = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            closeButton

            ScrollView {
                content
                    .padding(.top, Constants.ConnectionSheet.headerGap)
                    .padding(.horizontal, Constants.ConnectionSheet.inset)
                    .padding(.bottom, max(
                        Constants.ConnectionSheet.minimumBottomPadding,
                        Constants.ConnectionSheet.bottomSpacing - bottomSafeAreaInset
                    ))
                    .frame(maxWidth: .infinity)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            #if !os(visionOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomSafeAreaInset = $0 }
        .background(backgroundColor ?? Constants.ConnectionSheet.defaultBackground(for: colorScheme))
        .presentationBackground(backgroundColor ?? Constants.ConnectionSheet.defaultBackground(for: colorScheme))
        .presentationCornerRadius(Constants.ConnectionSheet.cornerRadius)
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(isDismissDisabled)
        .presentationDetents([
            .height(contentHeight > 0
                ? contentHeight + Constants.ConnectionSheet.closeSize + Constants.ConnectionSheet.inset
                : initialHeight)
        ])
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(.connectionClose)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: Constants.ConnectionSheet.glyphSize, height: Constants.ConnectionSheet.glyphSize)
                .frame(width: Constants.ConnectionSheet.closeSize, height: Constants.ConnectionSheet.closeSize)
                .contentShape(.rect)
        }
        .buttonStyle(IntentContentButtonStyle())
        .disabled(isDismissDisabled)
        .foregroundStyle(isDismissDisabled
            ? Constants.ConnectionSheet.disabledForeground(for: colorScheme)
            : (closeForeground ?? Constants.ConnectionSheet.defaultForeground(for: colorScheme)))
        .accessibilityLabel("Close")
        .accessibilityIdentifier("connection-sheet.close")
        .padding(.horizontal, Constants.ConnectionSheet.inset)
        .padding(.top, Constants.ConnectionSheet.inset)
    }
}
