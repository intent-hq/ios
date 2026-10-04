@testable import Intent
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ImagePasteboardFixture {
    var items: [[String: Any]]
    private(set) var readCount = 0

    init(items: [[String: Any]] = []) {
        self.items = items
    }

    var source: ImagePasteboard {
        ImagePasteboard(
            hasImages: { self.items.contains { $0.keys.contains { UTType($0)?.conforms(to: .image) == true } } },
            itemTypes: { self.items.map { $0.keys.sorted() } },
            data: { type, index in
                self.readCount += 1
                return self.items[index][type] as? Data
            }
        )
    }
}

@MainActor
final class TextPasteKeyCommandTextView: KeyCommandTextView {
    var pastedText = ""

    override func pasteStandardContent(_: Any?) {
        insertText(pastedText)
    }
}

@MainActor
final class TextPasteWorkspacePromptTextView: WorkspacePromptUITextView {
    var pastedText = ""

    override func pasteStandardContent(_: Any?) {
        insertText(pastedText)
    }
}
