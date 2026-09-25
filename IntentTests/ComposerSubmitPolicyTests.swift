@testable import Intent
import Testing
import UIKit

/// The composer's bare-Return submit rule (`ComposerSubmitPolicy`): visionOS
/// is dictation-first — Return submits only while a hardware keyboard is
/// connected — while iPad always submits and iPhone always inserts a newline.
struct ComposerSubmitPolicyTests {
    // MARK: - visionOS: hardware-keyboard gated

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
        // Only the keyboard state matters on visionOS (compatibility idioms
        // included).
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

    // MARK: - iOS: idiom gated, keyboard state irrelevant

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
        textView.traitOverrides.preferredContentSizeCategory = .large
        textView.traitOverrides.legibilityWeight = .regular
        let draft = "Keep this draft\nand its selection"
        textView.text = draft
        let selection = NSRange(location: 5, length: 4)
        textView.selectedRange = selection
        textView.layoutIfNeeded()
        let regular = try #require(textView.font)
        let regularHeight = textView.naturalHeight
        #expect(regular.fontName == "Inter-Regular")
        #expect(regular.pointSize == 16)

        // Change the live view traits, not the font helper: this catches a
        // missing trait registration as well as an accidentally fixed-size font.
        textView.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        textView.traitOverrides.legibilityWeight = .bold
        textView.layoutIfNeeded()
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
