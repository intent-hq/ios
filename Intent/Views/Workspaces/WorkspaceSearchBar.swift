import SwiftUI

struct WorkspaceSearchBar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var viewMode: ViewMode
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: Constants.WorkspaceSearch.contentSpacing) {
            HStack(spacing: Constants.WorkspaceSearch.contentSpacing) {
                Picker("View", selection: $viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Button {
                    isExpanded = true
                    isFocused.wrappedValue = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .frame(width: Constants.WorkspaceSearch.buttonSize, height: Constants.WorkspaceSearch.buttonSize)
                        .background(Theme.muted(for: colorScheme), in: RoundedRectangle(cornerRadius: Constants.WorkspaceSearch.cornerRadius))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search workspaces")
                .accessibilityIdentifier("workspaces.search.open")
            }
            if isExpanded {
                searchInput
            }
        }
        .padding(.horizontal, Constants.WorkspaceList.pickerHorizontalPadding)
        .padding(.vertical, Constants.WorkspaceList.pickerVerticalPadding)
    }

    private var searchInput: some View {
        HStack(spacing: Constants.WorkspaceSearch.contentSpacing) {
            searchField
            Button("Cancel") {
                text = ""
                isFocused.wrappedValue = false
                isExpanded = false
            }
            .accessibilityIdentifier("workspaces.search.cancel")
        }
    }

    private var searchField: some View {
        HStack(spacing: Constants.WorkspaceSearch.contentSpacing) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search workspaces", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused(isFocused)
                .accessibilityIdentifier("workspaces.search.field")
                .onAppear { isFocused.wrappedValue = true }
                .onSubmit { isFocused.wrappedValue = false }
            if !text.isEmpty {
                Button {
                    text = ""
                    isFocused.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("workspaces.search.clear")
            }
        }
        .padding(.horizontal, Constants.WorkspaceSearch.horizontalPadding)
        .frame(minHeight: Constants.WorkspaceSearch.buttonSize)
        .background(Theme.muted(for: colorScheme), in: RoundedRectangle(cornerRadius: Constants.WorkspaceSearch.cornerRadius))
    }
}
