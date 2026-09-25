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
                viewModeSwitcher

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

    private var viewModeSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(ViewMode.allCases, id: \.self) { mode in
                Button {
                    viewMode = mode
                } label: {
                    Text(mode.rawValue)
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: Constants.WorkspaceSearch.segmentHeight)
                        .foregroundStyle(viewMode == mode ? Theme.background(for: colorScheme) : Theme.foreground(for: colorScheme))
                        .background(
                            viewMode == mode ? Theme.foreground(for: colorScheme) : Color.clear,
                            in: RoundedRectangle(cornerRadius: Constants.WorkspaceSearch.segmentCornerRadius)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: Constants.WorkspaceSearch.segmentCornerRadius))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(viewMode == mode ? .isSelected : [])
                .accessibilityIdentifier("workspaces.viewMode.\(mode.rawValue)")
            }
        }
        .padding(Constants.WorkspaceSearch.segmentInset)
        .background(Theme.muted(for: colorScheme), in: RoundedRectangle(cornerRadius: Constants.WorkspaceSearch.cornerRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace view")
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
