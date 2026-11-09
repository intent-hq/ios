import SwiftUI

struct CodeBlockView: View {
    let code: String
    let language: String?
    @Environment(\.assistantMessageStreaming) private var isStreaming
    @State private var copied = false
    @ScaledMetric(relativeTo: .caption) private var copyIconSide: CGFloat = 12

    var body: some View {
        if language == "mermaid" {
            if isStreaming {
                MermaidStreamingPlaceholder()
            } else {
                MermaidDiagramView(source: code)
            }
        } else {
            sourceView
        }
    }

    private var sourceView: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            codeContent
        }
        .background(Constants.Colors.CodeBlock.background)
        .clipShape(RoundedRectangle(cornerRadius: Constants.Conversation.CodeBlock.cornerRadius))
        .contextMenu {
            Button {
                HapticManager.impact(.light)
                UIPasteboard.general.string = code
            } label: {
                Label("Copy Code", image: "Copy")
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
                HStack(spacing: Constants.Conversation.CodeBlock.copyLabelSpacing) {
                    Image(copied ? .check : .copy)
                        .resizable()
                        .scaledToFit()
                        .frame(width: copyIconSide, height: copyIconSide)
                        .accessibilityHidden(true)
                    Text(copied ? "Copied" : "Copy")
                        .interFont(Constants.Typography.subtextXXS)
                }
                .font(.caption)
                .foregroundStyle(Constants.Colors.CodeBlock.action)
                .copyContextMenuPassthrough()
            }
            .buttonStyle(IntentContentButtonStyle())
        }
        .padding(.horizontal, Constants.Conversation.CodeBlock.horizontalPadding)
        .padding(.vertical, Constants.Conversation.CodeBlock.headerVerticalPadding)
    }

    private var codeContent: some View {
        ScrollView(.horizontal) {
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(Constants.Colors.CodeBlock.foreground)
                .textSelection(.enabled)
                .padding(.horizontal, Constants.Conversation.CodeBlock.horizontalPadding)
                .padding(.bottom, Constants.Conversation.CodeBlock.codeBottomPadding)
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
