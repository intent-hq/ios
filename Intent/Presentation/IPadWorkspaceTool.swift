import CoreTransferable
import Foundation
import UniformTypeIdentifiers

nonisolated enum IPadWorkspaceTool: Equatable, Identifiable {
    case browser(WorkspaceBrowser)
    case terminal(MobileTerminal)

    var id: String {
        switch self {
        case let .browser(browser): "browser-\(browser.id)"
        case let .terminal(terminal): "terminal-\(terminal.id)"
        }
    }

    var workspaceId: String {
        switch self {
        case let .browser(browser): browser.workspaceId
        case let .terminal(terminal): terminal.workspaceId
        }
    }

    var title: String {
        switch self {
        case let .browser(browser): browser.title
        case let .terminal(terminal): terminal.name
        }
    }
}

nonisolated struct IPadToolDrag: Codable, Transferable {
    let windowId: UUID
    let toolId: String
    let workspaceId: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "com.intent.workspace-tool"))
    }
}
