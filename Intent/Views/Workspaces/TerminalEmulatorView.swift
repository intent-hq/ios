import SwiftTerm
import SwiftUI
import UIKit

struct TerminalEmulatorView: UIViewRepresentable {
    let connection: MobileTerminalConnection
    private static let fontSize: CGFloat = 14

    func makeCoordinator() -> Coordinator { Coordinator(connection: connection) }

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: .zero)
        view.font = .monospacedSystemFont(ofSize: Self.fontSize, weight: .regular)
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = .white
        view.terminalDelegate = context.coordinator
        view.accessibilityLabel = "Workspace terminal"
        connection.outputHandler = { [weak view] data, reset in
            if reset { view?.feed(text: "\u{1b}c") }
            view?.feed(byteArray: Array(data)[...])
        }
        return view
    }

    func updateUIView(_ view: SwiftTerm.TerminalView, context: Context) {
        view.isUserInteractionEnabled = connection.isReady
        if connection.isReady, !context.coordinator.hasFocused {
            context.coordinator.hasFocused = true
            view.becomeFirstResponder()
        }
    }

    static func dismantleUIView(_ view: SwiftTerm.TerminalView, coordinator: Coordinator) {
        view.terminalDelegate = nil
        coordinator.connection.outputHandler = nil
        coordinator.connection.detach()
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        let connection: MobileTerminalConnection
        var hasFocused = false

        init(connection: MobileTerminalConnection) { self.connection = connection }

        func sizeChanged(source _: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            connection.resize(columns: newCols, rows: newRows)
        }

        func send(source _: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            connection.send(Data(data))
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
