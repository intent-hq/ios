import SwiftUI
import UIKit

/// TextKit 2 lays out the visible viewport rather than one giant SwiftUI Text.
/// Keep its native selection and scrolling; never access the legacy layoutManager.
struct WorkspaceTextFileView: UIViewRepresentable {
    let file: WorkspaceTextFile
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context _: Context) -> LineNumberTextView {
        let view = LineNumberTextView()
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
        view.setSource(file.content, index: file.lineIndex)
        view.accessibilityIdentifier = "text.content"
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateUIView(_ view: LineNumberTextView, context: Context) {
        context.coordinator.update(view, file: file, dark: colorScheme == .dark)
    }

    static func dismantleUIView(_: LineNumberTextView, coordinator: Coordinator) {
        coordinator.cancel()
    }

    @MainActor
    final class Coordinator {
        private var file: WorkspaceTextFile?
        private var dark = false
        private var task: Task<Void, Never>?
        private var revision = UUID()

        func update(_ view: LineNumberTextView, file: WorkspaceTextFile, dark: Bool) {
            guard self.file !== file || self.dark != dark else { return }
            cancel()
            if self.file !== file { view.setSource(file.content, index: file.lineIndex) }
            self.file = file
            self.dark = dark
            Self.apply([], to: view)
            guard file.byteCount <= FileSyntaxHighlighter.maxBytes else { return }
            let revision = revision
            task = Task { [weak self, weak view] in
                let runs = await FileSyntaxHighlighter.shared.highlight(
                    source: file.content, path: file.url.lastPathComponent, dark: dark
                )
                guard !Task.isCancelled, let self, self.revision == revision, let view else { return }
                Self.apply(runs, to: view)
            }
        }

        func cancel() {
            revision = UUID()
            task?.cancel()
            task = nil
        }

        static func apply(_ runs: [FileSyntaxRun], to view: UITextView) {
            let selection = view.selectedRange
            let offset = view.contentOffset
            let storage = view.textStorage
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: UIColor.label, range: NSRange(location: 0, length: storage.length))
            for run in runs {
                storage.addAttribute(.foregroundColor, value: run.uiColor, range: run.range)
            }
            storage.endEditing()
            view.selectedRange = selection
            view.setContentOffset(offset, animated: false)
        }
    }
}
