@testable import Intent
import Testing
import UIKit

struct ComposerSubmitPolicyTests {
    @Test func visionOSSubmitsWithHardwareKeyboard() {
        #expect(ComposerSubmitPolicy.returnSubmits(
            isVisionOS: true,
            idiom: .vision,
            hasHardwareKeyboard: true
        ))
    }

    @Test func visionOSInsertsNewlineWithoutHardwareKeyboard() {
        #expect(!ComposerSubmitPolicy.returnSubmits(
            isVisionOS: true,
            idiom: .vision,
            hasHardwareKeyboard: false
        ))
    }

    @Test func visionOSRuleIgnoresIdiom() {
        #expect(ComposerSubmitPolicy.returnSubmits(
            isVisionOS: true,
            idiom: .pad,
            hasHardwareKeyboard: true
        ))
        #expect(!ComposerSubmitPolicy.returnSubmits(
            isVisionOS: true,
            idiom: .pad,
            hasHardwareKeyboard: false
        ))
    }

    @Test func padAlwaysSubmits() {
        #expect(ComposerSubmitPolicy.returnSubmits(
            isVisionOS: false,
            idiom: .pad,
            hasHardwareKeyboard: false
        ))
        #expect(ComposerSubmitPolicy.returnSubmits(
            isVisionOS: false,
            idiom: .pad,
            hasHardwareKeyboard: true
        ))
    }

    @Test func phoneNeverSubmits() {
        #expect(!ComposerSubmitPolicy.returnSubmits(
            isVisionOS: false,
            idiom: .phone,
            hasHardwareKeyboard: false
        ))
        #expect(!ComposerSubmitPolicy.returnSubmits(
            isVisionOS: false,
            idiom: .phone,
            hasHardwareKeyboard: true
        ))
    }

    @MainActor
    @Test func composerRefreshesTypographyWithoutLosingDraftOrSelection() throws {
        let textView = KeyCommandTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        let controller = UIViewController()
        controller.view.addSubview(textView)
        let window = UIWindow(frame: textView.frame)
        window.rootViewController = controller
        window.traitOverrides.preferredContentSizeCategory = .large
        window.traitOverrides.legibilityWeight = .regular
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        window.updateTraitsIfNeeded()
        window.layoutIfNeeded()
        try #require(textView.window === window)
        #expect(textView.traitCollection.preferredContentSizeCategory == .large)
        #expect(textView.traitCollection.legibilityWeight == .regular)
        let draft = "Keep this draft\nand its selection"
        textView.text = draft
        let selection = NSRange(location: 5, length: 4)
        textView.selectedRange = selection
        textView.layoutIfNeeded()
        let regular = try #require(textView.font)
        let regularHeight = textView.naturalHeight
        #expect(regular.fontName == "Inter-Regular")
        #expect(regular.pointSize == 16)

        window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        window.traitOverrides.legibilityWeight = .bold
        window.updateTraitsIfNeeded()
        textView.layoutIfNeeded()
        #expect(textView.traitCollection.preferredContentSizeCategory == .accessibilityExtraExtraExtraLarge)
        #expect(textView.traitCollection.legibilityWeight == .bold)
        let accessible = try #require(textView.font)
        let base = try #require(UIFont(name: "Inter-SemiBold", size: 16))
        let reference = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: base,
            compatibleWith: textView.traitCollection
        )
        #expect(accessible.fontName == "Inter-SemiBold")
        #expect(accessible.pointSize == reference.pointSize)
        #expect(textView.naturalHeight > regularHeight)
        #expect(textView.text == draft)
        #expect(textView.selectedRange == selection)

        textView.insertText("edited")
        #expect(textView.text == "Keep edited draft\nand its selection")
        #expect(textView.selectedRange == NSRange(location: 11, length: 0))
    }
}
