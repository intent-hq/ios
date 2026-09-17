import SwiftUI

struct CodeBlockView: View {
    let code: String
    let language: String?
    @State private var copied = false

    private static let copyLabelSpacing: CGFloat = 4
    private static let horizontalPadding: CGFloat = 12
    private static let headerVerticalPadding: CGFloat = 8
    private static let codeBottomPadding: CGFloat = 12
    private static let cornerRadius: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            codeContent
        }
        .background(Constants.Colors.CodeBlock.background)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .contextMenu {
            Button {
                HapticManager.impact(.light)
                UIPasteboard.general.string = code
            } label: {
                Label("Copy Code", systemImage: "doc.on.doc")
            }
        }
    }

    private var header: some View {
        HStack {
            if let lang = language, !lang.isEmpty {
                Text(lang)
                    .font(.caption.monospaced())
                    .foregroundStyle(Constants.Colors.CodeBlock.secondaryLabel)
            }
            Spacer()
            Button {
                copyCode()
            } label: {
                HStack(spacing: Self.copyLabelSpacing) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .accessibilityHidden(true)
                    Text(copied ? "Copied" : "Copy")
                }
                .font(.caption)
                .foregroundStyle(Constants.Colors.CodeBlock.action)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Self.headerVerticalPadding)
    }

    private var codeContent: some View {
        ScrollView(.horizontal) {
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(Constants.Colors.CodeBlock.foreground)
                .textSelection(.enabled)
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.bottom, Self.codeBottomPadding)
        }
        .scrollIndicators(.hidden)
    }

    private func copyCode() {
        HapticManager.impact(.light)
        UIPasteboard.general.string = code
        copied = true
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Constants.Conversation.CodeBlock.copyConfirmationDuration
        ) {
            copied = false
        }
    }
}
