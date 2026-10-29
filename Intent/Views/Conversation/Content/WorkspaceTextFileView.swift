import SwiftUI
import UIKit

/// TextKit 2 lays out the visible viewport rather than one giant SwiftUI Text.
/// Keep its native selection and scrolling; never access the legacy layoutManager.
struct WorkspaceTextFileView: UIViewRepresentable {
    let file: WorkspaceTextFile

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.textContainer.widthTracksTextView = true
        view.textContainer.lineBreakMode = .byWordWrapping
        view.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedSystemFont(ofSize: UIFont.systemFontSize, weight: .regular)
        )
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "text.content"
        context.coordinator.display(file, in: view)
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.display(file, in: view)
    }

    static func dismantleUIView(_: UITextView, coordinator: Coordinator) {
        coordinator.cancelHighlighting()
    }

    @MainActor
    final class Coordinator {
        private var file: WorkspaceTextFile?
        private var highlightTask: Task<Void, Never>?

        deinit { highlightTask?.cancel() }

        func display(_ file: WorkspaceTextFile, in view: UITextView) {
            // Avoid comparing/copying megabytes on unrelated SwiftUI updates.
            guard self.file !== file else { return }
            cancelHighlighting()
            self.file = file
            view.textColor = .label
            view.text = file.content
            guard file.byteCount <= WorkspaceSyntaxHighlighter.maxBytes else { return }
            highlightTask = Task { [weak self, weak view] in
                guard let tokens = try? await WorkspaceSyntaxHighlighter.highlight(
                    text: file.content, path: file.url.lastPathComponent
                ), !Task.isCancelled, let self, self.file === file, let view else { return }
                // Color edits preserve the font, selection, and scroll position.
                // textStorage is supported by TextKit 2; layoutManager is not.
                view.textStorage.beginEditing()
                for token in tokens {
                    view.textStorage.addAttribute(
                        .foregroundColor, value: WorkspaceSyntaxTheme.color(for: token.scope), range: token.range
                    )
                }
                view.textStorage.endEditing()
                highlightTask = nil
            }
        }

        func cancelHighlighting() {
            highlightTask?.cancel()
            highlightTask = nil
        }
    }
}
