import SwiftUI

struct WorkspaceSearchBar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var viewMode: ViewMode
    @Binding var isSearching: Bool
    var horizontalPadding: CGFloat = Constants.WorkspaceList.pickerHorizontalPadding
    var isCompact = false
    @ScaledMetric(relativeTo: .body) private var segmentTracking: CGFloat = -0.32

    private var controlHeight: CGFloat {
        isCompact ? Constants.WorkspaceSearch.compactHeight : Constants.WorkspaceSearch.expandedHeight
    }

    private var segmentInset: CGFloat {
        isCompact ? Constants.WorkspaceSearch.compactSegmentInset : Constants.WorkspaceSearch.segmentInset
    }

    var body: some View {
        VStack(spacing: Constants.WorkspaceSearch.contentSpacing) {
            HStack(spacing: Constants.WorkspaceSearch.contentSpacing) {
                viewModeSwitcher

                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: Constants.WorkspaceSearch.focusAnimationDuration)) {
                        isSearching = true
                    }
                } label: {
                    Image(.search)
                        .resizable()
                        .scaledToFit()
                        .frame(width: Constants.WorkspaceSearch.iconSize, height: Constants.WorkspaceSearch.iconSize)
                        .foregroundStyle(Constants.Pairing.foreground(for: colorScheme))
                        .frame(width: controlHeight, height: controlHeight)
                        .background(
                            Constants.WorkspaceList.controlSurface(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: Constants.WorkspaceSearch.cornerRadius, style: .circular)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search workspaces")
                .accessibilityIdentifier("workspaces.search.open")
            }
        }
        .padding(.horizontal, horizontalPadding)
    }

    private var viewModeSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(ViewMode.allCases, id: \.self) { mode in
                Button {
                    viewMode = mode
                } label: {
                    Text(mode.rawValue)
                        .interFont(Constants.Typography.bodySEmphasized)
                        .tracking(segmentTracking)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: controlHeight - segmentInset * 2)
                        .foregroundStyle(viewMode == mode
                            ? Constants.Pairing.foreground(for: colorScheme == .dark ? .light : .dark)
                            : Constants.Pairing.foreground(for: colorScheme))
                        .background(
                            viewMode == mode ? Constants.Pairing.foreground(for: colorScheme) : Color.clear,
                            in: RoundedRectangle(cornerRadius: Constants.WorkspaceSearch.segmentCornerRadius, style: .circular)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: Constants.WorkspaceSearch.segmentCornerRadius, style: .circular))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(viewMode == mode ? .isSelected : [])
                .accessibilityIdentifier("workspaces.viewMode.\(mode.rawValue)")
            }
        }
        .padding(segmentInset)
        .background(
            Constants.WorkspaceList.controlSurface(for: colorScheme),
            in: RoundedRectangle(cornerRadius: Constants.WorkspaceSearch.cornerRadius, style: .circular)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace view")
    }
}

struct WorkspaceSearchInput: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var text: String
    @Binding var isSearching: Bool
    var isFocused: FocusState<Bool>.Binding
    @ScaledMetric(relativeTo: .body) private var inputTracking: CGFloat = -0.32

    var body: some View {
        HStack(spacing: Constants.WorkspaceSearch.contentSpacing) {
            searchField
            Button {
                text = ""
                isFocused.wrappedValue = false
                withAnimation(reduceMotion ? nil : .easeInOut(duration: Constants.WorkspaceSearch.focusAnimationDuration)) {
                    isSearching = false
                }
            } label: {
                Image(.close)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Constants.WorkspaceSearch.iconSize, height: Constants.WorkspaceSearch.iconSize)
                    .foregroundStyle(Constants.Pairing.foreground(for: colorScheme))
                    .frame(width: Constants.WorkspaceSearch.compactHeight, height: Constants.WorkspaceSearch.compactHeight)
                    .background(
                        Constants.WorkspaceList.controlSurface(for: colorScheme),
                        in: RoundedRectangle(cornerRadius: Constants.WorkspaceSearch.cornerRadius, style: .circular)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close search")
            .accessibilityIdentifier("workspaces.search.cancel")
        }
        .padding(.horizontal, Constants.WorkspaceSearch.contentSpacing)
        .padding(.vertical, Constants.WorkspaceSearch.bottomPadding)
    }

    private var searchField: some View {
        HStack(spacing: Constants.WorkspaceSearch.contentSpacing) {
            TextField("Search workspaces", text: $text)
                .interFont(Constants.Typography.bodyS)
                .tracking(inputTracking)
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
                    Image(.closeCircle)
                        .resizable()
                        .scaledToFit()
                        .frame(width: Constants.WorkspaceSearch.iconSize, height: Constants.WorkspaceSearch.iconSize)
                        .foregroundStyle(contrast == .increased
                            ? Theme.mutedForeground(for: colorScheme, contrast: contrast)
                            : Constants.Pairing.mutedForeground(for: colorScheme))
                        .accessibilityHidden(true)
                        .frame(minWidth: Constants.Accessibility.minimumTapTarget, minHeight: Constants.Accessibility.minimumTapTarget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("workspaces.search.clear")
            }
        }
        .padding(.leading, Constants.WorkspaceSearch.inputLeadingInset)
        .padding(.trailing, Constants.WorkspaceSearch.contentSpacing)
        .frame(minHeight: Constants.WorkspaceSearch.compactHeight)
        .background(
            Constants.WorkspaceList.controlSurface(for: colorScheme),
            in: RoundedRectangle(cornerRadius: Constants.WorkspaceSearch.cornerRadius, style: .circular)
        )
    }
}
