@testable import Intent
import SwiftUI
import Testing
import UIKit

@MainActor
struct ComposerFocusBindingTests {
    @Test(arguments: [false, true], [false, true])
    func editingCallbackWinsOverTheEarlierRenderFocus(editing: Bool, renderQueuedFirst: Bool) async {
        var focused = !editing
        let adapter = SubmittableTextView(
            text: .constant(""),
            isFocused: Binding(get: { focused }, set: { focused = $0 })
        ) {}
        let coordinator = adapter.makeCoordinator()
        let editor = FocusTrackingTextView()
        editor.clearRecordedFocusRequests()
        editor.delegate = coordinator
        editor.responder = editing

        if renderQueuedFirst { coordinator.synchronizeFocus(in: editor) }
        if editing {
            coordinator.textViewDidBeginEditing(editor)
        } else {
            coordinator.textViewDidEndEditing(editor)
        }
        if !renderQueuedFirst { coordinator.synchronizeFocus(in: editor) }
        await drainFocusCallbacks()

        #expect(focused == editing)
        #expect(editor.isFirstResponder == editing)
        #expect(editor.focusRequests.isEmpty, "A stale render must not undo native focus")
    }

    @Test(arguments: [false, true])
    func newerBindingValueCancelsQueuedFocusRequest(requested: Bool) async {
        var focused = requested
        let adapter = SubmittableTextView(
            text: .constant(""),
            isFocused: Binding(get: { focused }, set: { focused = $0 })
        ) {}
        let coordinator = adapter.makeCoordinator()
        let editor = FocusTrackingTextView()
        editor.clearRecordedFocusRequests()
        editor.delegate = coordinator
        editor.responder = !requested

        coordinator.synchronizeFocus(in: editor)
        focused = !requested
        await drainFocusCallbacks()

        #expect(focused == !requested)
        #expect(editor.isFirstResponder == !requested)
        #expect(editor.focusRequests.isEmpty, "Queued focus work must honor the latest binding")
    }

    @Test func explicitFocusAndDismissalStillReachTheEditor() async {
        var focused = true
        let adapter = SubmittableTextView(
            text: .constant(""),
            isFocused: Binding(get: { focused }, set: { focused = $0 })
        ) {}
        let coordinator = adapter.makeCoordinator()
        let editor = FocusTrackingTextView()
        editor.clearRecordedFocusRequests()
        editor.delegate = coordinator

        coordinator.synchronizeFocus(in: editor)
        await drainFocusCallbacks()
        #expect(editor.isFirstResponder)
        #expect(focused)

        focused = false
        coordinator.synchronizeFocus(in: editor)
        await drainFocusCallbacks()
        #expect(!editor.isFirstResponder)
        #expect(!focused)
        #expect(editor.focusRequests == [true, false])
    }

    private func drainFocusCallbacks() async {
        for _ in 0..<2 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

@MainActor
private final class FocusTrackingTextView: KeyCommandTextView {
    var responder = false
    private(set) var focusRequests: [Bool] = []

    override var isFirstResponder: Bool { responder }

    func clearRecordedFocusRequests() {
        focusRequests.removeAll()
    }

    override func becomeFirstResponder() -> Bool {
        focusRequests.append(true)
        responder = true
        delegate?.textViewDidBeginEditing?(self)
        return true
    }

    override func resignFirstResponder() -> Bool {
        focusRequests.append(false)
        responder = false
        delegate?.textViewDidEndEditing?(self)
        return true
    }
}
