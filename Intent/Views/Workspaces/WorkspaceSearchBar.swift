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
    @State private var switcherWidth: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var segmentTracking: CGFloat = -0.32

    private var controlHeight: CGFloat {
        isCompact ? Constants.WorkspaceSearch.compactHeight : Constants.WorkspaceSearch.expandedHeight
    }

    private var segmentInset: CGFloat {
        isCompact ? Constants.WorkspaceSearch.compactSegmentInset : Constants.WorkspaceSearch.segmentInset
    }

    var body: some View {
        HStack(spacing: Constants.WorkspaceSearch.contentSpacing) {
            if !isSearching {
                viewModeSwitcher
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { switcherWidth = $0 }
                    .transition(reduceMotion ? .identity : .offset(x: -switcherWidth - horizontalPadding))

                WorkspaceSearchSlot(height: controlHeight, isSearching: false)
                    .frame(width: controlHeight)
                    .transition(.identity)
            }
        }
        .frame(maxWidth: .infinity)
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

struct WorkspaceSearchPresentation: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var text: String
    @Binding var isSearching: Bool
    var isFocused: FocusState<Bool>.Binding
    @State private var motion = WorkspaceSearchMotion()
    @State private var measuredPlacement: WorkspaceSearchPlacement?
    @State private var fieldContentWidth: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var inputHeight = Constants.WorkspaceSearch.expandedHeight

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isSearching {
                    WorkspaceSearchSlot(height: max(inputHeight, Constants.WorkspaceSearch.expandedHeight), isSearching: true)
                        .padding(.horizontal, Constants.WorkspaceSearch.contentSpacing)
                        .padding(.vertical, Constants.WorkspaceSearch.bottomPadding)
                        .transition(.identity)
                }
            }
            .overlay {
                WorkspaceSearchControl(
                    text: $text,
                    isSearching: $isSearching,
                    isFocused: isFocused,
                    fieldContentWidth: fieldContentWidth,
                    frame: motion.placement?.frame ?? .zero,
                    progress: motion.placement?.isSearching == true ? 1 : 0
                )
                .opacity(motion.placement == nil ? 0 : 1)
                .allowsHitTesting(motion.placement != nil)
                .accessibilityHidden(motion.placement == nil)
            }
            .onPreferenceChange(WorkspaceSearchBounds.self) { measuredPlacement = $0 }
            .onChange(of: measuredPlacement) { _, next in updatePlacement(next) }
            .coordinateSpace(name: WorkspaceSearchBounds.coordinateSpace)
            .animation(reduceMotion ? nil : .smooth(duration: Constants.WorkspaceSearch.morphAnimationDuration), value: isSearching)
    }

    private func updatePlacement(_ next: WorkspaceSearchPlacement?) {
        var nextMotion = motion
        guard let next, let update = nextMotion.update(next, isSearching: isSearching, reduceMotion: reduceMotion) else { return }
        let animation: Animation? = update.animated ? .smooth(duration: Constants.WorkspaceSearch.morphAnimationDuration) : nil
        withAnimation(animation, completionCriteria: .removed) {
            if next.isSearching {
                fieldContentWidth = max(0, next.frame.width - next.frame.height - Constants.WorkspaceSearch.contentSpacing)
            }
            motion = nextMotion
        } completion: {
            motion.complete(revision: update.revision)
        }
    }
}

private struct WorkspaceSearchControl: View, Animatable {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var text: String
    @Binding var isSearching: Bool
    var isFocused: FocusState<Bool>.Binding
    var fieldContentWidth: CGFloat
    nonisolated var frame: CGRect
    nonisolated var progress: CGFloat
    @State private var closingText = ""
    @ScaledMetric(relativeTo: .body) private var inputTracking: CGFloat = -0.32

    nonisolated var animatableData: AnimatablePair<CGRect.AnimatableData, CGFloat> {
        get { AnimatablePair(frame.animatableData, progress) }
        set {
            frame.animatableData = newValue.first
            progress = newValue.second
        }
    }

    private var size: CGSize { frame.size }

    private var splitProgress: CGFloat {
        phase(from: Constants.WorkspaceSearch.compactTravelCompletion, to: Constants.WorkspaceSearch.splitCompletion)
    }

    private var controlWidth: CGFloat {
        let expansion = phase(from: Constants.WorkspaceSearch.compactTravelCompletion, to: Constants.WorkspaceSearch.expansionCompletion)
        return size.height + max(0, size.width - size.height) * expansion
    }

    private var fieldVisibility: CGFloat {
        phase(from: Constants.WorkspaceSearch.fieldFadeStart, to: Constants.WorkspaceSearch.fieldFadeEnd)
    }

    private var fieldWidth: CGFloat {
        max(size.height, controlWidth - (size.height + Constants.WorkspaceSearch.contentSpacing) * splitProgress)
    }

    private var fieldTravelOffset: CGFloat {
        let travel = phase(from: Constants.WorkspaceSearch.compactTravelCompletion, to: 1)
        let separation = sin(.pi * travel)
        return reduceMotion ? 0 : -Constants.WorkspaceSearch.fieldTravelLag * separation * separation
    }

    private var controlShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Constants.WorkspaceSearch.cornerRadius, style: .circular)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            searchField
                .frame(width: fieldContentWidth)
                .opacity(fieldVisibility)
                .frame(width: fieldWidth, height: size.height, alignment: .leading)
                .background(Constants.WorkspaceList.controlSurface(for: colorScheme))
                .clipShape(controlShape)
                .offset(x: max(0, size.width - controlWidth), y: fieldTravelOffset)
                .allowsHitTesting(isSearching)
                .accessibilityHidden(!isSearching)

            searchButton
                .frame(width: size.height, height: size.height)
                .background(Constants.WorkspaceList.controlSurface(for: colorScheme), in: controlShape)
                .offset(x: max(0, size.width - size.height))
        }
        .frame(width: size.width, height: size.height, alignment: .leading)
        .position(x: frame.midX, y: frame.midY)
        // Geometry and contents already use the same interpolated progress.
        .transaction { $0.animation = nil }
        .onChange(of: isSearching) { _, searching in
            if !searching { isFocused.wrappedValue = false }
        }
    }

    private var searchButton: some View {
        Button {
            if isSearching {
                closingText = text
                text = ""
                isFocused.wrappedValue = false
            }
            withAnimation(reduceMotion ? nil : .smooth(duration: Constants.WorkspaceSearch.morphAnimationDuration)) {
                isSearching.toggle()
            }
        } label: {
            Image(isSearching || progress > 0 ? .close : .search)
                .resizable()
                .scaledToFit()
                .frame(width: Constants.WorkspaceSearch.iconSize, height: Constants.WorkspaceSearch.iconSize)
                .foregroundStyle(Constants.Pairing.foreground(for: colorScheme))
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSearching ? "Close search" : "Search workspaces")
        .accessibilityIdentifier(isSearching ? "workspaces.search.cancel" : "workspaces.search.open")
    }

    private var searchField: some View {
        HStack(spacing: Constants.WorkspaceSearch.contentSpacing) {
            if isSearching {
                TextField("Search", text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused(isFocused)
                    .accessibilityIdentifier("workspaces.search.field")
                    .onAppear { isFocused.wrappedValue = true }
                    .onSubmit { isFocused.wrappedValue = false }
                    .transition(.identity)
            } else {
                Text(closingText.isEmpty ? "Search" : closingText)
                    .foregroundStyle(closingText.isEmpty ? Constants.Pairing.mutedForeground(for: colorScheme) : Constants.Pairing.foreground(for: colorScheme))
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
            if isSearching, !text.isEmpty {
                clearButton
            }
        }
        .interFont(Constants.Typography.bodyS)
        .tracking(inputTracking)
        .padding(.leading, Constants.WorkspaceSearch.inputLeadingInset)
        .padding(.trailing, Constants.WorkspaceSearch.inputTrailingInset)
        .padding(.vertical, Constants.WorkspaceSearch.inputVerticalInset)
    }

    private var clearButton: some View {
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

    private func phase(from start: CGFloat, to end: CGFloat) -> CGFloat {
        min(1, max(0, (progress - start) / (end - start)))
    }
}

private struct WorkspaceSearchSlot: View {
    var height: CGFloat
    var isSearching: Bool
    @State private var frame: CGRect = .zero

    var body: some View {
        Color.clear
            .frame(height: height)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(WorkspaceSearchBounds.coordinateSpace))
            } action: { frame = $0 }
            .preference(
                key: WorkspaceSearchBounds.self,
                value: frame.isEmpty ? nil : WorkspaceSearchPlacement(frame: frame, isSearching: isSearching)
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct WorkspaceSearchBounds: PreferenceKey {
    nonisolated static let coordinateSpace = "workspaceSearch"
    nonisolated static var defaultValue: WorkspaceSearchPlacement? { nil }

    nonisolated static func reduce(value: inout WorkspaceSearchPlacement?, nextValue: () -> WorkspaceSearchPlacement?) {
        value = nextValue() ?? value
    }
}
