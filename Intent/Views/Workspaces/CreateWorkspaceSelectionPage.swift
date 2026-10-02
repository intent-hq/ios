import SwiftUI

private enum CreateWorkspaceCoordinates {
    static let content = "creation.selectionContent"
}

struct CreateWorkspaceSelectionPage<HeadingAction: View, LeadingAction: View, Content: View>: View {
    let title: LocalizedStringKey
    let titleIdentifier: String
    @Binding var searchText: String
    let searchPlaceholder: LocalizedStringKey?
    let searchIdentifier: String
    let searchButtonShowsBackground: Bool
    let isSearchEnabled: Bool
    let isLoading: Bool
    let isNextDisabled: Bool
    let onNext: (() -> Void)?
    let headingAction: HeadingAction
    let leadingAction: LeadingAction
    let content: Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSearching = false
    @State private var viewportHeight: CGFloat = 0
    @State private var searchScrollOffset: CGFloat = 0
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @FocusState private var searchFocused: Bool

    init(
        title: LocalizedStringKey,
        titleIdentifier: String,
        searchText: Binding<String> = .constant(""),
        searchPlaceholder: LocalizedStringKey? = nil,
        searchIdentifier: String = "creation.search",
        searchButtonShowsBackground: Bool = true,
        isSearchEnabled: Bool = true,
        isLoading: Bool = false,
        isNextDisabled: Bool = false,
        onNext: (() -> Void)? = nil,
        @ViewBuilder headingAction: () -> HeadingAction = { EmptyView() },
        @ViewBuilder leadingAction: () -> LeadingAction = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.titleIdentifier = titleIdentifier
        _searchText = searchText
        self.searchPlaceholder = searchPlaceholder
        self.searchIdentifier = searchIdentifier
        self.searchButtonShowsBackground = searchButtonShowsBackground
        self.isSearchEnabled = isSearchEnabled
        self.isLoading = isLoading
        self.isNextDisabled = isNextDisabled
        self.onNext = onNext
        self.headingAction = headingAction()
        self.leadingAction = leadingAction()
        self.content = content()
    }

    var body: some View {
        scrollView
        .environment(\.workspaceSelectionResultHeight, isSearching ? viewportHeight : 0)
        .overlay {
            if isLoading {
                ProgressView()
                    .accessibilityLabel("Loading")
                    .accessibilityIdentifier("\(titleIdentifier).loading")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomControls }
        .onAppear {
            if !searchText.isEmpty { isSearching = true }
        }
        .onDisappear { searchFocused = false }
        .foregroundStyle(CreateWorkspaceRepoStyle.foreground(for: colorScheme))
        .background(CreateWorkspaceRepoStyle.background(for: colorScheme))
    }

    private var scrollView: some View {
        ScrollView { pageContent }
            .scrollPosition($scrollPosition)
            #if !os(visionOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .onScrollGeometryChange(for: CreateWorkspaceScrollSize.self) { geometry in
                CreateWorkspaceScrollSize(
                    viewportHeight: geometry.containerSize.height,
                    contentHeight: geometry.contentSize.height
                )
            } action: { _, size in
                viewportHeight = size.viewportHeight
                if isSearching {
                    scrollPosition.scrollTo(y: searchScrollOffset)
                }
            }
            .onPreferenceChange(CreateWorkspaceResultsOffset.self) { offset in
                searchScrollOffset = max(0, offset - CreateWorkspaceFormStyle.pagePadding)
                if isSearching { scrollPosition.scrollTo(y: searchScrollOffset) }
            }
            .onChange(of: searchText) { _, query in
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    scrollPosition.scrollTo(y: searchScrollOffset)
                }
            }
            .onChange(of: isSearching) { _, searching in
                if searching {
                    scrollPosition.scrollTo(y: searchScrollOffset)
                } else {
                    scrollPosition.scrollTo(edge: .top)
                }
            }
    }

    private var pageContent: some View {
        VStack(alignment: .leading, spacing: CreateWorkspaceRepoStyle.titleSpacing) {
            heading
                .padding(.top, CreateWorkspaceFormStyle.headingTopPadding)
            if !isLoading {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CreateWorkspaceFormStyle.pagePadding)
        .coordinateSpace(name: CreateWorkspaceCoordinates.content)
    }

    private var heading: some View {
        HStack(spacing: Constants.WorkspaceSearch.contentSpacing) {
            Text(title)
                .interFont(Constants.Typography.heading2)
                .tracking(CreateWorkspaceRepoStyle.titleTracking)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(titleIdentifier)
            headingAction
            if let searchPlaceholder {
                WorkspaceSearchButton(
                    isSearching: $isSearching,
                    label: searchPlaceholder,
                    identifier: "\(searchIdentifier).open",
                    showsBackground: searchButtonShowsBackground
                )
                .opacity(isSearching || !isSearchEnabled ? 0 : 1)
                .allowsHitTesting(!isSearching && isSearchEnabled)
                .accessibilityHidden(isSearching || !isSearchEnabled)
            }
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 0) {
            if let onNext {
                HStack {
                    leadingAction
                    Spacer()
                    CreateWorkspaceNextButton(isDisabled: isNextDisabled, onNext: onNext)
                }
                .padding(.horizontal, CreateWorkspaceFormStyle.pagePadding)
                .padding(.top, CreateWorkspaceFormStyle.rowSpacing)
                .padding(.bottom, isSearching ? CreateWorkspaceFormStyle.rowSpacing : CreateWorkspaceFormStyle.pagePadding)
            }
            searchInput
        }
    }

    @ViewBuilder
    private var searchInput: some View {
        if let searchPlaceholder, isSearching {
            WorkspaceSearchInput(
                text: $searchText,
                isSearching: $isSearching,
                isFocused: $searchFocused,
                placeholder: searchPlaceholder,
                identifierPrefix: searchIdentifier
            )
            .background(CreateWorkspaceRepoStyle.background(for: colorScheme))
            .transition(reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct CreateWorkspaceScrollSize: Equatable {
    let viewportHeight: CGFloat
    let contentHeight: CGFloat
}

private struct CreateWorkspaceResultsOffset: PreferenceKey {
    static var defaultValue: CGFloat { 0 }

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

extension EnvironmentValues {
    @Entry var workspaceSelectionResultHeight: CGFloat = 0
}

struct CreateWorkspaceSearchResults<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.workspaceSelectionResultHeight) private var minimumHeight
    @State private var offset: CGFloat = 0

    var body: some View {
        content
            .frame(minHeight: minimumHeight, alignment: .topLeading)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.frame(in: .named(CreateWorkspaceCoordinates.content)).minY
            } action: { offset = $0 }
            .preference(key: CreateWorkspaceResultsOffset.self, value: offset)
    }
}
