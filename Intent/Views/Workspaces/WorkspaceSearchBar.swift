import SwiftUI

struct WorkspaceSearchBar: View {
    private static let selectionAnimationDuration = 0.35

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var viewMode: ViewMode
    @Binding var isSearching: Bool
    var horizontalPadding: CGFloat = Constants.WorkspaceList.pickerHorizontalPadding
    var isCompact = false
    @Namespace private var selectionAnimation
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

                WorkspaceSearchButton(isSearching: $isSearching, height: controlHeight)
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
                        .contentShape(RoundedRectangle(cornerRadius: Constants.WorkspaceSearch.segmentCornerRadius, style: .circular))
                }
                .buttonStyle(.plain)
                .matchedGeometryEffect(id: mode, in: selectionAnimation)
                .accessibilityAddTraits(viewMode == mode ? .isSelected : [])
                .accessibilityIdentifier("workspaces.viewMode.\(mode.rawValue)")
            }
        }
        .background {
            RoundedRectangle(cornerRadius: Constants.WorkspaceSearch.segmentCornerRadius, style: .circular)
                .fill(Constants.Pairing.foreground(for: colorScheme))
                .matchedGeometryEffect(id: viewMode, in: selectionAnimation, isSource: false)
        }
        .padding(segmentInset)
        .background(
            Constants.WorkspaceList.controlSurface(for: colorScheme),
            in: RoundedRectangle(cornerRadius: Constants.WorkspaceSearch.cornerRadius, style: .circular)
        )
        .animation(reduceMotion ? nil : .snappy(duration: Self.selectionAnimationDuration), value: viewMode)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace view")
    }
}

struct WorkspaceSearchButton: View {
    @Binding var isSearching: Bool
    var height: CGFloat = Constants.WorkspaceSearch.expandedHeight
    var label: LocalizedStringKey = "Search workspaces"
    var identifier = "workspaces.search.open"
    var showsBackground = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
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
                .frame(width: height, height: height)
                .contentShape(.rect)
                .background {
                    if showsBackground { WorkspaceControlSurface() }
                }
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

struct WorkspaceSearchInput: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var text: String
    @Binding var isSearching: Bool
    var isFocused: FocusState<Bool>.Binding
    var placeholder: LocalizedStringKey = "Search workspaces"
    var identifierPrefix = "workspaces.search"
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
                    .frame(width: Constants.WorkspaceSearch.expandedHeight, height: Constants.WorkspaceSearch.expandedHeight)
                    .background { WorkspaceControlSurface() }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close search")
            .accessibilityIdentifier("\(identifierPrefix).cancel")
        }
        .padding(.horizontal, Constants.WorkspaceSearch.contentSpacing)
        .padding(.vertical, Constants.WorkspaceSearch.bottomPadding)
    }

    private var searchField: some View {
        HStack(spacing: Constants.WorkspaceSearch.contentSpacing) {
            TextField(placeholder, text: $text)
                .interFont(Constants.Typography.bodyS)
                .tracking(inputTracking)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused(isFocused)
                .accessibilityIdentifier("\(identifierPrefix).field")
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
                .accessibilityIdentifier("\(identifierPrefix).clear")
            }
        }
        .padding(.leading, Constants.WorkspaceSearch.inputLeadingInset)
        .padding(.trailing, Constants.WorkspaceSearch.inputTrailingInset)
        .padding(.vertical, Constants.WorkspaceSearch.inputVerticalInset)
        .frame(minHeight: Constants.WorkspaceSearch.expandedHeight)
        .background { WorkspaceControlSurface() }
    }
}

struct WorkspaceControlSurface: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: Constants.WorkspaceSearch.cornerRadius, style: .circular)
            .fill(Constants.Pairing.surface(for: colorScheme))
            .shadow(
                color: .black.opacity(colorScheme == .light ? Constants.WorkspaceSearch.surfaceShadowOpacity : 0),
                radius: Constants.WorkspaceSearch.surfaceShadowRadius,
                y: Constants.WorkspaceSearch.surfaceShadowOffset
            )
    }
}
