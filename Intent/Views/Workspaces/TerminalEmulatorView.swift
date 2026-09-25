import SwiftTerm
import SwiftUI
import UIKit

struct TerminalEmulatorView: UIViewRepresentable {
    let connection: MobileTerminalConnection
    let controls: MobileTerminalControls

    func makeCoordinator() -> Coordinator { Coordinator(connection: connection, controls: controls) }

    func makeUIView(context: Context) -> TerminalCanvasView {
        let view = TerminalCanvasView(frame: .zero)
        view.font = .monospacedSystemFont(ofSize: TerminalAppearance.terminalFontSize, weight: .regular)
        view.nativeBackgroundColor = TerminalAppearance.canvas
        view.nativeForegroundColor = TerminalAppearance.foreground
        view.caretColor = TerminalAppearance.accent
        view.keyboardAppearance = .dark
        view.inputAccessoryView = nil
        controls.terminalView = view
        view.focusChanged = { [weak controls] in controls?.synchronize() }
        view.terminalDelegate = context.coordinator
        view.accessibilityLabel = "Workspace terminal"
        connection.outputHandler = { [weak view] data, reset in
            if reset { view?.feed(text: "\u{1b}c") }
            view?.feed(byteArray: Array(data)[...])
        }
        return view
    }

    func updateUIView(_ view: TerminalCanvasView, context: Context) {
        view.isUserInteractionEnabled = connection.isReady
        if connection.isReady, !context.coordinator.hasFocused {
            context.coordinator.hasFocused = true
            _ = view.becomeFirstResponder()
        }
    }

    static func dismantleUIView(_ view: TerminalCanvasView, coordinator: Coordinator) {
        view.focusChanged = nil
        coordinator.controls.terminalView = nil
        view.terminalDelegate = nil
        coordinator.connection.outputHandler = nil
        coordinator.connection.detach()
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        let connection: MobileTerminalConnection
        let controls: MobileTerminalControls
        var hasFocused = false

        init(connection: MobileTerminalConnection, controls: MobileTerminalControls) {
            self.connection = connection
            self.controls = controls
        }

        func sizeChanged(source _: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            connection.resize(columns: newCols, rows: newRows)
        }

        func send(source _: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            connection.send(Data(data))
            Task { @MainActor [weak controls] in controls?.synchronize() }
        }

        func setTerminalTitle(source _: SwiftTerm.TerminalView, title _: String) {}
        func hostCurrentDirectoryUpdate(source _: SwiftTerm.TerminalView, directory _: String?) {}
        func scrolled(source _: SwiftTerm.TerminalView, position _: Double) {}
        func requestOpenLink(source _: SwiftTerm.TerminalView, link _: String, params _: [String: String]) {}
        func bell(source _: SwiftTerm.TerminalView) {}
        func clipboardCopy(source _: SwiftTerm.TerminalView, content _: Data) {}
        func clipboardRead(source _: SwiftTerm.TerminalView) -> Data? { nil }
        func iTermContent(source _: SwiftTerm.TerminalView, content _: ArraySlice<UInt8>) {}
        func rangeChanged(source _: SwiftTerm.TerminalView, startY _: Int, endY _: Int) {}
    }
}
