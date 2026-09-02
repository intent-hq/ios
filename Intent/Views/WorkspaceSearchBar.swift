import SwiftUI

/// Shared system-search configuration for workspace lists on iPhone and iPad.
struct WorkspaceSearchModifier: ViewModifier {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        content.searchable(
            text: $text,
            prompt: "Search workspaces"
        )
        .searchFocused(isFocused)
    }
}

extension View {
    func workspaceSearch(
        text: Binding<String>,
        isFocused: FocusState<Bool>.Binding
    ) -> some View {
        modifier(WorkspaceSearchModifier(text: text, isFocused: isFocused))
    }
}
