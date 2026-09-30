import Foundation

/// Pure counterpart of the desktop manifest detector; discovery never registers or runs a script.
nonisolated enum WorkspaceScriptDiscovery {
    static let manifestPaths = ["package.json", "Makefile", "Cargo.toml", "pyproject.toml"]

    private struct Candidate {
        let name: String
        let command: String
        let source: String
    }

    static func scripts(workspaceId: String, files: [String: String], fileNames: Set<String>) -> [WorkspaceScript] {
        let candidates = packageScripts(files["package.json"] ?? "", fileNames: fileNames)
            + makeScripts(files["Makefile"] ?? "")
            + cargoScripts(files["Cargo.toml"] ?? "")
            + pythonScripts(files["pyproject.toml"] ?? "")
        var usedNames: Set<String> = []
        return candidates.map { candidate in
            let name = uniqueName(candidate, usedNames: &usedNames)
            return WorkspaceScript(
                id: "manifest:\(candidate.source):\(candidate.name)",
                workspaceId: workspaceId,
                name: name,
                command: candidate.command,
                mode: mode(for: candidate.name),
                isRegistered: false
            )
        }
    }

    private static func packageScripts(_ content: String, fileNames: Set<String>) -> [Candidate] {
        guard let data = content.data(using: .utf8),
              let package = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let scripts = package["scripts"] as? [String: Any] else { return [] }
        let manager = packageManager(package["packageManager"] as? String, fileNames: fileNames)
        return scripts.keys.sorted().compactMap { name in
            guard let command = scripts[name] as? String,
                  !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !command.contains("\0"), let quoted = shellName(name) else { return nil }
            return Candidate(name: name, command: "\(manager) run \(quoted)", source: "package.json")
        }
    }

    private static func packageManager(_ declared: String?, fileNames: Set<String>) -> String {
        if let declared {
            let value = declared.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = value.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            if let name = parts.first, ["pnpm", "yarn", "npm", "bun"].contains(String(name)),
               value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
               parts.count == 1 || !parts[1].isEmpty { return String(name) }
        }
        if fileNames.contains("pnpm-lock.yaml") { return "pnpm" }
        if fileNames.contains("yarn.lock") { return "yarn" }
        if fileNames.contains("bun.lock") || fileNames.contains("bun.lockb") { return "bun" }
        return "npm"
    }

    private static func shellName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-"),
              name.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        if name.range(of: #"^[A-Za-z0-9_./:@%+=,-]+$"#, options: .regularExpression) != nil { return name }
        return "'" + name.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func makeScripts(_ content: String) -> [Candidate] {
        let pattern = #"^([A-Za-z0-9][A-Za-z0-9_.-]*(?:\s+[A-Za-z0-9][A-Za-z0-9_.-]*)*)\s*::?(?:\s|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var targets: [String] = []
        var seen: Set<String> = []
        for line in content.components(separatedBy: .newlines) {
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line) else { continue }
            for target in line[range].split(whereSeparator: \.isWhitespace) {
                let name = String(target)
                if seen.insert(name).inserted { targets.append(name) }
            }
        }
        return targets.map { Candidate(name: $0, command: "make \($0)", source: "Makefile") }
    }

    private static func cargoScripts(_ content: String) -> [Candidate] {
        guard matches(#"(?m)^\[(package|workspace)\]|^\[\[bin\]\]"#, in: content) else { return [] }
        return ["build", "test", "check"].map { Candidate(name: $0, command: "cargo \($0)", source: "Cargo.toml") }
    }

    private static func pythonScripts(_ content: String) -> [Candidate] {
        let hasPytest = matches(#"(?m)^\[tool\.pytest(?:\.ini_options)?\]"#, in: content)
        let hasRuff = matches(#"(?m)^\[tool\.ruff(?:\]|\.)"#, in: content)
        let hasBlack = matches(#"(?m)^\[tool\.black\]"#, in: content)
        let hasMypy = matches(#"(?m)^\[tool\.mypy\]"#, in: content)
        let hasPyright = matches(#"(?m)^\[tool\.pyright\]"#, in: content)
        var scripts: [Candidate] = []
        if hasPytest { scripts.append(Candidate(name: "test", command: "pytest", source: "pyproject.toml")) }
        if hasRuff { scripts.append(Candidate(name: "lint", command: "ruff check .", source: "pyproject.toml")) }
        if hasBlack || hasRuff {
            scripts.append(Candidate(name: "format", command: hasBlack ? "black ." : "ruff format .", source: "pyproject.toml"))
        }
        if hasMypy || hasPyright {
            scripts.append(Candidate(name: "typecheck", command: hasMypy ? "mypy ." : "pyright", source: "pyproject.toml"))
        }
        return scripts
    }

    private static func matches(_ pattern: String, in content: String) -> Bool {
        content.range(of: pattern, options: .regularExpression) != nil
    }

    private static func uniqueName(_ candidate: Candidate, usedNames: inout Set<String>) -> String {
        var name = candidate.name
        if usedNames.contains(name) {
            let prefix: String
            switch candidate.source {
            case "Makefile": prefix = "make"
            case "Cargo.toml": prefix = "cargo"
            case "pyproject.toml": prefix = "python"
            default: prefix = "script"
            }
            let prefixed = "\(prefix):\(name)"
            name = prefixed
            var suffix = 2
            while usedNames.contains(name) {
                name = "\(prefixed)-\(suffix)"
                suffix += 1
            }
        }
        usedNames.insert(name)
        return name
    }

    private static func mode(for name: String) -> String {
        let lower = name.lowercased()
        let services: Set<String> = ["dev", "start", "serve", "develop", "storybook", "watch", "preview"]
        let commands: Set<String> = ["build", "test", "lint", "typecheck", "type-check", "format", "fmt", "prettier", "eslint", "check"]
        if services.contains(lower) { return "service" }
        if commands.contains(lower) { return "command" }
        let prefixes: [(String, String)] = [
            ("dev:", "service"), ("dev-", "service"), ("start:", "service"), ("start-", "service"),
            ("build:", "command"), ("build-", "command"), ("test:", "command"), ("test-", "command"),
            ("lint:", "command"), ("lint-", "command"), ("format:", "command"), ("format-", "command"),
            ("typecheck:", "command"), ("type-check:", "command"), ("storybook:", "service"),
            ("watch:", "service"), ("watch-", "service")
        ]
        if let match = prefixes.first(where: { lower.hasPrefix($0.0) }) { return match.1 }
        // The desktop's remaining substring categories all have command mode.
        return lower.contains("storybook") ? "service" : "command"
    }
}
