import Foundation

struct NewRepositoryDraft: Equatable {
    private static let maxNameBytes = 255
    var name = ""
    var parentPath = "~/Developer"

    var validationError: String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = parentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return String(localized: "Enter a repository name.") }
        guard !name.allSatisfy({ $0 == "." }),
              name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\<>:\"|?*").union(.controlCharacters)) == nil else {
            return String(localized: "Use a name without path separators or special characters.")
        }
        guard name.utf8.count <= Self.maxNameBytes else { return String(localized: "The repository name is too long.") }
        guard parent == "~" || parent.hasPrefix("~/") || parent.hasPrefix("/") else {
            return String(localized: "Enter a folder starting with / or ~/ on your connected computer.")
        }
        guard parent.rangeOfCharacter(from: .controlCharacters) == nil,
              !parent.contains("\\"),
              !parent.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            return String(localized: "Enter a folder without . or .. path components.")
        }
        return nil
    }

    var repositoryPath: String? {
        guard validationError == nil else { return nil }
        let parent = parentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = parent.split(separator: "/")
        let prefix = parent.hasPrefix("/") ? "/" : ""
        let normalizedParent = prefix + components.joined(separator: "/")
        let separator = normalizedParent.hasSuffix("/") ? "" : "/"
        return normalizedParent + separator + name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func destinationError(for response: Any) -> String? {
        guard let status = response as? [String: Any], let exists = status["exists"] as? Bool else {
            return String(localized: "Could not check this folder. Try again.")
        }
        return exists ? String(localized: "A file or folder already exists here. Choose a different name or parent folder.") : nil
    }
}

enum WorkspaceRepositorySource {
    case github(url: String, baseRef: String)
    case newRepository(path: String)

    var parameters: [String: Any] {
        switch self {
        case let .github(url, baseRef):
            ["githubUrl": url, "baseRef": baseRef]
        case let .newRepository(path):
            ["repositoryPath": path, "isNewRepo": true]
        }
    }
}
