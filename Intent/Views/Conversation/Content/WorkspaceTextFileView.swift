import SwiftUI
import UIKit

/// TextKit 2 lays out the visible viewport rather than one giant SwiftUI Text.
/// Keep its native selection and scrolling; never access the legacy layoutManager.
struct WorkspaceTextFileView: UIViewRepresentable {
    let file: WorkspaceTextFile

    func makeUIView(context _: Context) -> UITextView {
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
        view.text = file.content
        view.accessibilityIdentifier = "text.content"
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator(file: file) }

    func updateUIView(_ view: UITextView, context: Context) {
        // Avoid comparing/copying megabytes on unrelated SwiftUI updates.
        guard context.coordinator.file !== file else { return }
        context.coordinator.file = file
        view.text = file.content
    }

    final class Coordinator {
        var file: WorkspaceTextFile

        init(file: WorkspaceTextFile) { self.file = file }
    }
}
