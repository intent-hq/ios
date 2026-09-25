import Observation
import SwiftTerm
import UIKit

@MainActor
@Observable
final class MobileTerminalControls {
    private(set) var isKeyboardVisible = false
    private(set) var isControlEnabled = false
    @ObservationIgnored weak var terminalView: TerminalCanvasView?

    func toggleKeyboard() {
        guard let terminalView else { return }
        if terminalView.isFirstResponder {
            _ = terminalView.resignFirstResponder()
        } else {
            _ = terminalView.becomeFirstResponder()
        }
    }

    func toggleControl() {
        guard let terminalView else { return }
        terminalView.controlModifier.toggle()
        synchronize()
    }

    func insert(_ text: String) {
        terminalView?.insertText(text)
        synchronize()
    }

    func escape() {
        terminalView?.send(txt: "\u{1b}")
    }

    func arrow(_ direction: Arrow) {
        guard let terminalView else { return }
        let prefix = terminalView.getTerminal().applicationCursor ? "\u{1b}O" : "\u{1b}["
        terminalView.send(txt: prefix + direction.rawValue)
    }

    func synchronize() {
        isControlEnabled = terminalView?.controlModifier ?? false
        isKeyboardVisible = terminalView?.isFirstResponder ?? false
    }

    enum Arrow: String {
        case down = "B"
        case left = "D"
        case right = "C"
        case up = "A"
    }
}

final class TerminalCanvasView: SwiftTerm.TerminalView {
    var focusChanged: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        Task { @MainActor [weak self] in self?.focusChanged?() }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        Task { @MainActor [weak self] in self?.focusChanged?() }
        return result
    }
}
