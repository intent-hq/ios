import SwiftUI

/// Floating search bar shared by WorkspaceListView (iPhone) and WorkspaceListSidebar (iPad).
struct WorkspaceSearchBar: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .font(.subheadline)
                TextField("Search workspaces", text: $text)
                    .font(.subheadline)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                    .focused(isFocused)
                    .submitLabel(.search)
                    .onSubmit { isFocused.wrappedValue = false }
                if !text.isEmpty {
                    Button(action: { text = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                            .font(.subheadline)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.mutedForeground(for: colorScheme).opacity(0.2), lineWidth: 0.5)
            )

            if isFocused.wrappedValue {
                Button("Cancel") { isFocused.wrappedValue = false }
                    .font(.subheadline)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.2), value: isFocused.wrappedValue)
    }
}
