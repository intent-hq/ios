import SwiftUI

enum CreateWorkspaceScrollTarget: Hashable {
    case searchResults
    case top
}

struct CreateWorkspaceSelectionPage<Introduction: View, Content: View>: View {
    let title: LocalizedStringKey
    let titleIdentifier: String
    @Binding var searchText: String
    let searchPlaceholder: LocalizedStringKey?
    let searchIdentifier: String
    let isNextDisabled: Bool
    let onNext: (() -> Void)?
    let introduction: Introduction
    let content: Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSearching = false
    @State private var viewportHeight: CGFloat = 0
    @FocusState private var searchFocused: Bool

    init(
        title: LocalizedStringKey,
        titleIdentifier: String,
        searchText: Binding<String> = .constant(""),
        searchPlaceholder: LocalizedStringKey? = nil,
        searchIdentifier: String = "creation.search",
        isNextDisabled: Bool = false,
        onNext: (() -> Void)? = nil,
        @ViewBuilder introduction: () -> Introduction = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.titleIdentifier = titleIdentifier
        _searchText = searchText
        self.searchPlaceholder = searchPlaceholder
        self.searchIdentifier = searchIdentifier
        self.isNextDisabled = isNextDisabled
        self.onNext = onNext
        self.introduction = introduction()
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                pageContent
            }
            #if !os(visionOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom)
            } action: { _, height in
                viewportHeight = height
            }
            .onChange(of: searchText) { _, query in
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    proxy.scrollTo(CreateWorkspaceScrollTarget.searchResults, anchor: .top)
                }
            }
            .onChange(of: isSearching) { _, searching in
                proxy.scrollTo(searching ? CreateWorkspaceScrollTarget.searchResults : .top, anchor: .top)
            }
        }
        .environment(\.workspaceSelectionResultHeight, isSearching ? viewportHeight : 0)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomControls }
        .onAppear {
            if !searchText.isEmpty { isSearching = true }
        }
        .onDisappear { searchFocused = false }
        .foregroundStyle(CreateWorkspaceRepoStyle.foreground(for: colorScheme))
        .background(CreateWorkspaceRepoStyle.background(for: colorScheme))
    }

    private var pageContent: some View {
        VStack(alignment: .leading, spacing: CreateWorkspaceRepoStyle.sectionSpacing) {
            introduction
            VStack(alignment: .leading, spacing: CreateWorkspaceRepoStyle.titleSpacing) {
                heading
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CreateWorkspaceFormStyle.pagePadding)
        .id(CreateWorkspaceScrollTarget.top)
    }

    private var heading: some View {
        HStack(spacing: Constants.WorkspaceSearch.contentSpacing) {
            Text(title)
                .interFont(Constants.Typography.heading2)
                .tracking(CreateWorkspaceRepoStyle.titleTracking)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(titleIdentifier)
            if let searchPlaceholder {
                WorkspaceSearchButton(isSearching: $isSearching, label: searchPlaceholder, identifier: "\(searchIdentifier).open")
                    .opacity(isSearching ? 0 : 1)
                    .allowsHitTesting(!isSearching)
                    .accessibilityHidden(isSearching)
            }
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 0) {
            if let onNext {
                HStack {
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

extension EnvironmentValues {
    @Entry var workspaceSelectionResultHeight: CGFloat = 0
}

struct CreateWorkspaceSearchResults<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.workspaceSelectionResultHeight) private var minimumHeight

    var body: some View {
        content
            .frame(minHeight: minimumHeight, alignment: .topLeading)
            .id(CreateWorkspaceScrollTarget.searchResults)
    }
}
