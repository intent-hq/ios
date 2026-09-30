enum WorkspaceAction: String {
    case archive
    case delete

    var method: String { "workspace.\(rawValue)" }
    var label: String { self == .archive ? "Archive" : "Delete" }
    var title: String { "\(label) Workspace" }

    func message(workspaceTitle: String) -> String {
        switch self {
        case .archive:
            "Archive \"\(workspaceTitle)\"? Active work will stop. You can unarchive it later."
        case .delete:
            "Delete \"\(workspaceTitle)\"? This cannot be undone."
        }
    }
}
