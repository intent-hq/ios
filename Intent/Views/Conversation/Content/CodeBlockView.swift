import SwiftUI

struct CodeBlockView: View {
    let code: String
    let language: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with language label and copy button
            HStack {
                if let lang = language, !lang.isEmpty {
                    Text(lang)
                        .font(.caption.monospaced())
                        .foregroundStyle(Constants.Colors.CodeBlock.secondaryLabel)
                }
                Spacer()
                Button {
                    HapticManager.impact(.light)
                    UIPasteboard.general.string = code
                    copied = true
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + Constants.Conversation.CodeBlock.copyConfirmationDuration
                    ) {
                        copied = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy")
                    }
                    .font(.caption)
                    .foregroundStyle(Constants.Colors.CodeBlock.action)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Code content
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Constants.Colors.CodeBlock.foreground)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
        .background(Constants.Colors.CodeBlock.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button {
                HapticManager.impact(.light)
                UIPasteboard.general.string = code
            } label: {
                Label("Copy Code", systemImage: "doc.on.doc")
            }
        }
    }
}

