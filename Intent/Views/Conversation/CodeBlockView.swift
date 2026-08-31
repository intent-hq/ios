import SwiftUI

struct CodeBlockView: View {
    let code: String
    let language: String?
    @Environment(\.colorScheme) var colorScheme
    @State private var copied = false

    private var codeBackground: Color {
        colorScheme == .dark
            ? Color(white: 0.08)
            : Color(white: 0.12)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with language label and copy button
            HStack {
                if let lang = language, !lang.isEmpty {
                    Text(lang)
                        .font(.caption.monospaced())
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Button {
                    HapticManager.impact(.light)
                    UIPasteboard.general.string = code
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copied = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy")
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Code content
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
        .background(codeBackground)
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

