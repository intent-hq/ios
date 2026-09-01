import SwiftUI

/// Floating search bar shared by WorkspaceListView (iPhone) and WorkspaceListSidebar (iPad).
struct WorkspaceSearchBar: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: Constants.WorkspaceSearch.contentSpacing) {
            HStack(spacing: Constants.WorkspaceSearch.contentSpacing) {
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
            .padding(.horizontal, Constants.WorkspaceSearch.horizontalPadding)
            .padding(.vertical, Constants.WorkspaceSearch.verticalPadding)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: Constants.WorkspaceSearch.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Constants.WorkspaceSearch.cornerRadius)
                    .stroke(Theme.mutedForeground(for: colorScheme).opacity(
                        Constants.WorkspaceSearch.borderOpacity),
                        lineWidth: Constants.WorkspaceSearch.borderWidth)
            )

            if isFocused.wrappedValue {
                Button("Cancel") { isFocused.wrappedValue = false }
                    .font(.subheadline)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, Constants.WorkspaceSearch.horizontalPadding)
        .padding(.bottom, Constants.WorkspaceSearch.bottomPadding)
        .animation(.easeInOut(duration: Constants.WorkspaceSearch.focusAnimationDuration),
                   value: isFocused.wrappedValue)
    }
}
