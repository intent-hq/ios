import SwiftUI

private enum WorkspaceComposerMetrics {
    static let lineFragmentPadding: CGFloat = 5
    static let disabledOpacity: Double = 0.4
}

/// Workspace-only presentation; the owner retains draft, attachment and send behavior.
struct WorkspaceComposerRow: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    let isStreaming: Bool
    let hasAttachments: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onStop: () -> Void
    let onPhotos: () -> Void
    let onFiles: () -> Void
    var photosEnabled = true
    var onPasteImages: (() -> Void)?
    var skillCompletion: ComposerSkillCompletion?

    private typealias Design = Constants.Conversation.Design
    private typealias Layout = Design.Composer

    private var hasDraft: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasAttachments
    }

    var body: some View {
        HStack(spacing: Layout.controlSpacing - controlInset) {
            WorkspaceComposerEditor(text: $text, isFocused: $isFocused, onSend: onSend, onPasteImages: onPasteImages, skillCompletion: skillCompletion)
            WorkspaceAttachmentMenu(onPhotos: onPhotos, onFiles: onFiles, photosEnabled: photosEnabled)
            if hasDraft {
                WorkspaceComposerAction(isStop: false, action: onSend)
                    .disabled(!canSend)
            }
            if isStreaming {
                WorkspaceComposerAction(isStop: true, action: onStop)
            }
        }
        .padding(.leading, Layout.leadingPadding - editorInset)
        .padding(.trailing, hasDraft || isStreaming ? Layout.activeTrailingPadding : Layout.trailingPadding - controlInset)
        .padding(.vertical, (Layout.minimumHeight - Design.minimumTapTarget) / 2)
        .frame(minHeight: Layout.minimumHeight)
        .background(WorkspaceComposerSurface(text: text, hasAttachments: hasAttachments, isStreaming: isStreaming))
    }

    // UITextView's existing container inset and default line-fragment padding
    // already contribute to the reference's 20pt text inset.
    private var editorInset: CGFloat {
        Constants.Conversation.Composer.textContainerInset + WorkspaceComposerMetrics.lineFragmentPadding
    }
    private var controlInset: CGFloat { (Design.minimumTapTarget - Design.iconSize) / 2 }
}

/// Shared shape for the composer row and any pending attachment rows above it.
struct WorkspaceComposerSurface: View {
    let text: String
    let hasAttachments: Bool
    let isStreaming: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.conversationComposerBackgroundColor) private var backgroundColor

    private typealias Design = Constants.Conversation.Design

    private var isActive: Bool {
        isStreaming || hasAttachments || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        RoundedRectangle(cornerRadius: isActive ? Design.Composer.activeCornerRadius : Design.cornerRadius)
            .fill(backgroundColor ?? Design.Palette.surface(for: colorScheme))
    }
}

private struct WorkspaceComposerEditor: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    let onSend: () -> Void
    let onPasteImages: (() -> Void)?
    let skillCompletion: ComposerSkillCompletion?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var height = Constants.Conversation.Composer.minimumTextViewHeight

    private typealias Design = Constants.Conversation.Design

    var body: some View {
        ZStack(alignment: .leading) {
            SubmittableTextView(
                text: $text,
                isFocused: $isFocused,
                onSubmit: onSend,
                onPasteImages: onPasteImages,
                onHeightChange: { naturalHeight in
                    height = min(
                        max(naturalHeight, Constants.Conversation.Composer.minimumTextViewHeight),
                        Constants.Conversation.Composer.maximumTextViewHeight
                    )
                },
                accessibilityLabel: String(localized: "Message"),
                textColor: UIColor(Design.Palette.foreground(for: colorScheme)),
                skillCompletion: skillCompletion
            )
            .frame(height: height)
            if text.isEmpty {
                Text("Message")
                    .interFont(Constants.Typography.bodyS)
                    .tracking(Design.Typography.compactBodyTracking)
                    .foregroundStyle(Design.Palette.placeholderForeground(for: colorScheme, contrast: contrast))
                    .padding(.horizontal, Constants.Conversation.Composer.textContainerInset + WorkspaceComposerMetrics.lineFragmentPadding)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

struct WorkspaceAttachmentMenu: View {
    let onPhotos: () -> Void
    let onFiles: () -> Void
    var photosEnabled = true
    var glyphAlignment: Alignment = .center
    @ScaledMetric(relativeTo: .body) private var menuIconSide: CGFloat = 17
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private typealias Design = Constants.Conversation.Design

    var body: some View {
        Menu {
            Button(action: onPhotos) {
                Label {
                    Text("Photos")
                } icon: {
                    Image(.image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: menuIconSide, height: menuIconSide)
                }
            }
            .disabled(!photosEnabled)
            Button(action: onFiles) { Label("Files", image: "Folder") }
        } label: {
            Image(.paperclip)
                .resizable()
                .scaledToFit()
                .frame(width: Design.iconSize, height: Design.iconSize)
                .accessibilityHidden(true)
                .foregroundStyle(Design.Palette.placeholderForeground(for: colorScheme, contrast: contrast))
                .opacity(isEnabled ? 1 : WorkspaceComposerMetrics.disabledOpacity)
                .frame(minWidth: Design.minimumTapTarget, minHeight: Design.minimumTapTarget, alignment: glyphAlignment)
                .contentShape(Rectangle())
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel("Add attachment")
        .accessibilityIdentifier("composer.attachment")
    }
}

private struct WorkspaceComposerAction: View {
    let isStop: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    private typealias Design = Constants.Conversation.Design
    private typealias Layout = Design.Composer

    var body: some View {
        Button(action: action) {
            Group {
                if isStop {
                    RoundedRectangle(cornerRadius: Layout.stopCornerRadius)
                        .frame(width: Layout.stopSide, height: Layout.stopSide)
                } else {
                    Image(.arrowRight)
                        .resizable()
                        .scaledToFit()
                        .frame(width: Design.iconSize, height: Design.iconSize)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(Design.Palette.onAccent)
            .frame(width: Layout.actionWidth, height: Layout.actionHeight)
            .background(Design.Palette.accent, in: RoundedRectangle(cornerRadius: Design.innerCornerRadius))
            .opacity(isEnabled ? 1 : WorkspaceComposerMetrics.disabledOpacity)
            .frame(minWidth: Design.minimumTapTarget, minHeight: Design.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel(isStop ? "Stop response" : "Send message")
        .accessibilityIdentifier(isStop ? "composer.stop" : "composer.send")
    }
}
