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
}
