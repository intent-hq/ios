import CoreText
import SwiftUI

struct NoteListView: View {
    let workspaceId: String
    @Environment(AppCoordinator.self) var coordinator
    var noteStore: NoteStore
    @Environment(\.colorScheme) var colorScheme
    @State private var collapsedIds: Set<String> = []

    var body: some View {
        if noteStore.isLoading || !noteStore.hasLoaded, noteStore.notes.isEmpty {
            ProgressView {
                Text("Loading notes...").interFont(Constants.Typography.bodyS)
            }
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .frame(maxWidth: .infinity, minHeight: Constants.WorkspaceList.emptyStateHeight)
        } else if noteStore.sortedNotes.isEmpty {
            ContentUnavailableView {
                Label {
                    Text("No Notes").interFont(Constants.Typography.bodyM)
                } icon: {
                    Image(systemName: "doc.text")
                }
            } description: {
                Text("Notes will appear here when created.")
                    .interFont(Constants.Typography.bodyXS)
            }
            .frame(maxWidth: .infinity, minHeight: Constants.WorkspaceList.emptyStateHeight)
        } else {
            LazyVStack(spacing: WorkspaceDetailStyle.sectionSpacing) {
                ForEach(noteStore.rootNotes) { note in
                    NoteTreeNodeView(
                        note: note,
                        noteStore: noteStore,
                        workspaceId: workspaceId,
                        depth: 0,
                        collapsedIds: $collapsedIds,
                        colorScheme: colorScheme
                    )
                    .environment(coordinator)
                }
            }
            .padding(.horizontal, WorkspaceDetailStyle.pageInset)
            .padding(.bottom, WorkspaceDetailStyle.pageInset)
        }
    }
}

// MARK: - Tree Node View (recursive)

struct NoteTreeNodeView: View {
    let note: Note
    let noteStore: NoteStore
    let workspaceId: String
    let depth: Int
    @Binding var collapsedIds: Set<String>
    let colorScheme: ColorScheme
    @Environment(AppCoordinator.self) var coordinator

    private var hasChildren: Bool {
        noteStore.hasChildren(note.id)
    }

    private var isCollapsed: Bool {
        collapsedIds.contains(note.id)
    }

    private var children: [Note] {
        noteStore.childNotes(of: note.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            // This note's row — chevron and title have separate tap targets
            NoteRowView(
                note: note,
                allNotes: noteStore.notes,
                depth: depth,
                hasChildren: hasChildren,
                isCollapsed: isCollapsed,
                colorScheme: colorScheme,
                onToggleCollapse: toggleCollapse
            ) {
                coordinator.onSelectNote(note.id, workspaceId: workspaceId, noteTitle: note.title)
            }

            // Children (if expanded)
            if hasChildren, !isCollapsed {
                VStack(spacing: WorkspaceDetailStyle.taskRowSpacing) {
                    ForEach(children) { child in
                        Self(
                            note: child,
                            noteStore: noteStore,
                            workspaceId: workspaceId,
                            depth: depth + 1,
                            collapsedIds: $collapsedIds,
                            colorScheme: colorScheme
                        )
                        .environment(coordinator)
                    }
                }
                .padding(.top, depth == 0 ? WorkspaceDetailStyle.pageInset : WorkspaceDetailStyle.taskRowSpacing)
            }
        }
    }

    private func toggleCollapse() {
        withAnimation(.easeInOut(duration: Constants.Notes.List.expansionAnimationDuration)) {
            if collapsedIds.contains(note.id) {
                collapsedIds.remove(note.id)
            } else {
                collapsedIds.insert(note.id)
            }
        }
    }
}

// MARK: - Note Row View

struct NoteRowView: View {
    let note: Note
    /// Resolve live task progress from the complete note list.
    var allNotes: [Note] = []
    var depth: Int = 0
    var hasChildren: Bool = false
    var isCollapsed: Bool = false
    let colorScheme: ColorScheme
    var onToggleCollapse: (() -> Void)?
    var onNavigate: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var usesAccessibilityLayout: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if hasChildren {
                disclosure
            }
            noteButton
        }
        .padding(.leading, NoteRowLayout.indentation(for: depth, usesAccessibilityLayout: usesAccessibilityLayout))
    }

    private var disclosure: some View {
        Button { onToggleCollapse?() } label: {
            leadingIcon
                .frame(width: NoteRowLayout.disclosureTargetSize, alignment: .leading)
                .padding(.vertical, NoteRowLayout.tapTargetPadding)
                .contentShape(Rectangle())
        }
        .buttonStyle(IntentContentButtonStyle())
        .padding(.vertical, -NoteRowLayout.tapTargetPadding)
        .accessibilityLabel("Child notes for \(note.title)")
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        .accessibilityHint("Double-tap to \(isCollapsed ? "expand" : "collapse") child notes")
    }

    private var noteButton: some View {
        Button { onNavigate?() } label: {
            HStack(alignment: .top, spacing: WorkspaceDetailStyle.noteTextSpacing) {
                if !hasChildren {
                    leadingIcon
                        .frame(width: NoteRowLayout.disclosureTargetSize, alignment: .leading)
                }
                titleAndTags
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, hasChildren ? WorkspaceDetailStyle.noteTextSpacing : 0)
            .frame(
                minWidth: Constants.Accessibility.minimumTapTarget,
                maxWidth: .infinity,
                minHeight: WorkspaceDetailStyle.iconSize,
                alignment: .topLeading
            )
            .padding(.vertical, NoteRowLayout.tapTargetPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityIdentifier("workspace.note.\(note.id)")
        .padding(.vertical, -NoteRowLayout.tapTargetPadding)
    }

    private var leadingIcon: some View {
        WorkspaceNoteIcon(kind: NoteRowIcon.kind(for: note, notes: allNotes))
    }

    private var titleAndTags: some View {
        let visibleTags = NoteRowLayout.visibleTags(for: note)
        return VStack(alignment: .leading, spacing: visibleTags.isEmpty
            ? WorkspaceDetailStyle.notePreviewSpacing
            : WorkspaceDetailStyle.noteTitleSpacing) {
            NoteRowText(
                note.title,
                style: depth == 0 ? Constants.Typography.bodyM : Constants.Typography.bodyS,
                lineLimit: NoteRowLayout.titleLineLimit(usesAccessibilityLayout: usesAccessibilityLayout),
                alignsWithCheckbox: true
            )
                .tracking(depth == 0 ? WorkspaceDetailStyle.rowTitleTracking : WorkspaceDetailStyle.bodyTracking)
                .foregroundStyle(WorkspaceDetailStyle.foreground(for: colorScheme))
            if !visibleTags.isEmpty {
                HStack(spacing: Constants.Notes.List.contentSpacing) {
                    ForEach(visibleTags.prefix(Constants.Notes.List.maximumTagCount), id: \.self) { tag in
                        Text(tag)
                            .interFont(Constants.Typography.subtextXXS)
                            .padding(.horizontal, Constants.Notes.List.tagHorizontalPadding)
                            .padding(.vertical, Constants.Notes.List.tagVerticalPadding)
                            .background(Theme.muted(for: colorScheme))
                            .clipShape(RoundedRectangle(cornerRadius: Constants.Notes.List.tagCornerRadius))
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    }
                }
            } else if depth == 0, let preview = note.preview {
                NoteRowText(preview, style: Constants.Typography.bodyS, lineLimit: usesAccessibilityLayout ? nil : 1)
                    .tracking(WorkspaceDetailStyle.bodyTracking)
                    .foregroundStyle(WorkspaceDetailStyle.secondary(for: colorScheme, contrast: colorSchemeContrast))
            }
        }
    }
}

private struct NoteRowText: View {
    let text: String
    let style: Constants.Typography.Style
    let lineLimit: Int?
    let alignsWithCheckbox: Bool
    @Environment(\.legibilityWeight) private var legibilityWeight
    @ScaledMetric private var fontSize: CGFloat

    init(_ text: String, style: Constants.Typography.Style, lineLimit: Int?, alignsWithCheckbox: Bool = false) {
        self.text = text
        self.style = style
        self.lineLimit = lineLimit
        self.alignsWithCheckbox = alignsWithCheckbox
        _fontSize = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeTo)
    }

    var body: some View {
        let face = legibilityWeight == .bold ? style.face.legibleFace : style.face
        let font = CTFontCreateWithName(face.rawValue as CFString, fontSize, nil)
        let capHeight = CTFontGetCapHeight(font)
        WorkspaceTextTrimLayout(capHeight: capHeight) {
            Text(text)
                .interFont(style)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, alignsWithCheckbox ? max(0, (WorkspaceDetailStyle.iconSize - capHeight) / 2) : 0)
    }
}

enum NoteRowLayout {
    // Expand each button's hit area into the row gap without changing visible spacing.
    static let tapTargetPadding = (Constants.Accessibility.minimumTapTarget - WorkspaceDetailStyle.iconSize) / 2

    static var disclosureTargetSize: CGFloat {
        max(Constants.Notes.List.disclosureSize, Constants.Accessibility.minimumTapTarget)
    }

    static func indentation(for depth: Int, usesAccessibilityLayout: Bool) -> CGFloat {
        let width = usesAccessibilityLayout
            ? WorkspaceDetailStyle.accessibilityIndentation
            : WorkspaceDetailStyle.noteIndentation
        return CGFloat(max(0, depth)) * width
    }

    static func titleLineLimit(usesAccessibilityLayout: Bool) -> Int? {
        usesAccessibilityLayout ? nil : Constants.Notes.List.titleLineLimit
    }

    static func visibleTags(for note: Note) -> [String] {
        guard note.isDefault else { return note.tags }
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return note.tags.filter { tag in
            tag.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(title) != .orderedSame
        }
    }
}
