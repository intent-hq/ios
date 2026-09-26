import Foundation

extension ToolClassifier {
    struct ClassificationContext {
        let name: String
        let input: [String: AnyCodable]
        let clean: String
        let pathValue: String?
        let path: String?
        let command: String?
        let query: String?
        let informationRequest: String?
        let url: String?
        let acpTitle: String?
        let summary: String?

        init(name: String, input: [String: AnyCodable]) {
            self.name = name
            self.input = input
            clean = ToolClassifier.cleanToolName(name).lowercased()
            pathValue = input["path"]?.value as? String
            let filePath = input["file_path"]?.value as? String
            path = pathValue ?? filePath
            command = input["command"]?.value as? String
            query = input["query"]?.value as? String
            informationRequest = input["information_request"]?.value as? String
            url = input["url"]?.value as? String
            acpTitle = ToolClassifier.nonEmpty((input["_acpTitle"]?.value as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines))
            summary = ToolClassifier.nonEmpty((input["summary"]?.value as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func classify(name: String, input: [String: AnyCodable]) -> ToolDisplay {
        let context = ClassificationContext(name: name, input: input)
        if let display = classifyWorkspaceAndFiles(context) { return display }
        if let display = classifyExecutionAndSearch(context) { return display }
        if let display = classifyServices(context) { return display }
        if let display = classifyAgents(context) { return display }
        if let display = classifyNotesAndWorkspace(context) { return display }
        if let display = classifyTasksAndGit(context) { return display }
        return classifyFallback(context)
    }
}

private extension ToolClassifier {
    static func classifyWorkspaceAndFiles(_ context: ClassificationContext) -> ToolDisplay? {
        classifyWorkspaceAndReads(context) ?? classifyFileMutations(context)
    }

    static func classifyWorkspaceAndReads(_ context: ClassificationContext) -> ToolDisplay? {
        let input = context.input
        let clean = context.clean
        let p = context.path
        let acpTitle = context.acpTitle
        let summary = context.summary
        // workspace_api: prefer human-readable label over the raw tool name
        // (detected by name, or by input shape: code + summary)
        if clean == "workspace_api"
            || (input["code"]?.value is String && summary != nil) {
            let titleIsRawName = acpTitle.map { title in
                cleanToolName(title).lowercased() == "workspace_api"
            } ?? true
            if let label = titleIsRawName ? (summary ?? acpTitle) : (acpTitle ?? summary) {
                return ToolDisplay(
                    icon: .workspace,
                    verb: String(label.prefix(Constants.Conversation.ToolClassifier.titleMaximumLength)),
                    subject: nil,
                    path: nil
                )
            }
        }

        // File read
        if clean.contains("view") || clean.contains("read"),
           !clean.contains("terminal"),
           !clean.contains("process"),
           !clean.contains("agent"),
           !clean.contains("note") {
            let isDir = (input["type"]?.value as? String) == "directory"
            if let p {
                let hasSearch = input["search_query_regex"]?.value is String
                let verb = hasSearch ? "Search" : isDir ? "List" : "Read"
                return ToolDisplay(icon: .file, verb: verb, subject: filename(p), path: dirname(p))
            }
            // _acpTitle fallback: extract the path from e.g. "Read `src/foo.rs`"
            // (no end anchor: multi-line titles match on the first line, like desktop)
            if let title = acpTitle,
               let captured = firstCapture(#"^(?:Read|View|List\s+Contents?)\s+(.+)"#, in: title),
               let candidate = pathCandidate(captured) {
                let titleIsDir = isDir
                    || title.range(
                        of: #"^List\s+Contents?"#,
                        options: [.regularExpression, .caseInsensitive]
                    ) != nil
                return ToolDisplay(
                    icon: .file,
                    verb: titleIsDir ? "List" : "Read",
                    subject: filename(candidate),
                    path: dirname(candidate)
                )
            }
        }

        return nil
    }

    static func classifyFileMutations(_ context: ClassificationContext) -> ToolDisplay? {
        let input = context.input
        let clean = context.clean
        let p = context.path
        let acpTitle = context.acpTitle
        // File write/edit
        if clean.contains("edit") || clean.contains("str-replace") || clean.contains("str_replace")
            || clean.contains("save") || clean.contains("write"),
           !clean.contains("note"),
           !clean.contains("process") {
            let verb = (clean.contains("save") || clean.contains("write")) ? "Save" : "Edit"
            if p != nil || input["file_content"]?.value != nil || input["old_str_1"]?.value != nil {
                let file = p ?? ""
                return ToolDisplay(icon: .edit, verb: verb, subject: filename(file), path: dirname(file))
            }
            // _acpTitle fallback: extract the path from e.g. "Edit `src/foo.ts`"
            if let title = acpTitle,
               let captured = firstCapture(#"^(?:Edit|Save|Read|Write|Delete|View|Create)\s+(.+)"#, in: title),
               let candidate = pathCandidate(captured) {
                return ToolDisplay(
                    icon: .edit,
                    verb: verb,
                    subject: filename(candidate),
                    path: dirname(candidate)
                )
            }
        }

        // File delete
        if clean.contains("remove") || clean.contains("delete"),
           !clean.contains("note"),
           !clean.contains("comment") {
            if let paths = input["file_paths"]?.value as? [Any], !paths.isEmpty {
                if paths.count == 1, let first = paths[0] as? String {
                    return ToolDisplay(icon: .delete, verb: "Delete", subject: filename(first), path: dirname(first))
                }
                return ToolDisplay(icon: .delete, verb: "Delete", subject: "\(paths.count) files", path: nil)
            }
            if let p {
                return ToolDisplay(icon: .delete, verb: "Delete", subject: filename(p), path: dirname(p))
            }
        }

        return nil
    }
}

private extension ToolClassifier {
    static func classifyExecutionAndSearch(_ context: ClassificationContext) -> ToolDisplay? {
        classifyTerminal(context) ?? classifyScriptsContextAndSearch(context)
    }

    static func classifyTerminal(_ context: ClassificationContext) -> ToolDisplay? {
        let clean = context.clean
        // Terminal/process
        guard isTerminalTool(context) else { return nil }
        if let operation = terminalOperationDisplay(clean: clean) { return operation }
        let invocation = context.command.map(terminalCommandInvocation)
            ?? terminalTitleInvocation(context.acpTitle)
            ?? TerminalInvocation(verb: "Run", subject: nil)
        return ToolDisplay(icon: .terminal, verb: invocation.verb, subject: invocation.subject, path: nil)
    }

    private struct TerminalInvocation {
        let verb: String
        let subject: String?
    }

    private static func isTerminalTool(_ context: ClassificationContext) -> Bool {
        let clean = context.clean
        return clean.contains("process") || clean.contains("terminal") || clean.contains("bash")
            || clean.contains("shell") || clean == "run" || clean.hasPrefix("run ")
            || clean == "launch" || clean.hasPrefix("launch ") || context.command != nil
    }

    private static func terminalOperationDisplay(clean: String) -> ToolDisplay? {
        if clean.contains("read") {
            return ToolDisplay(icon: .terminal, verb: "Read", subject: "terminal", path: nil)
        }
        if clean.contains("write") {
            return ToolDisplay(icon: .terminal, verb: "Write to", subject: "terminal", path: nil)
        }
        if clean.contains("kill") {
            return ToolDisplay(icon: .terminal, verb: "Kill", subject: "terminal", path: nil)
        }
        if clean.contains("list") {
            return ToolDisplay(icon: .terminal, verb: "List", subject: "processes", path: nil)
        }
        return nil
    }

    private static func terminalCommandInvocation(_ command: String) -> TerminalInvocation {
        TerminalInvocation(verb: "Run", subject: truncatedCommand(command))
    }

    private static func terminalTitleInvocation(_ title: String?) -> TerminalInvocation? {
        guard let title else { return nil }
        // _acpTitle fallback: extract the verb/command from e.g. "Run `cargo test`",
        // "Kill terminal 5", "Launch `pnpm dev`" (desktop parity).
        let pattern = #"^(Run|Launch|Read|List|Kill|Write)\s+`?(.+?)`?\s*$"#
        guard let titleVerb = firstCapture(pattern, in: title, group: 1)?.lowercased(),
              let rest = firstCapture(pattern, in: title, group: 2)?
                  .trimmingCharacters(in: .whitespaces),
              !rest.isEmpty else {
            return nil
        }
        switch titleVerb {
        case "list": return TerminalInvocation(verb: "List", subject: rest)
        case "read": return TerminalInvocation(verb: "Read", subject: rest)
        case "kill": return TerminalInvocation(verb: "Kill", subject: rest)
        case "write": return TerminalInvocation(verb: "Write to", subject: rest)
        case "launch": return TerminalInvocation(verb: "Launch", subject: truncatedCommand(rest))
        default: return terminalCommandInvocation(rest)
        }
    }

    private static func truncatedCommand(_ command: String) -> String {
        String(String(command.split(separator: "\n").first ?? "")
            .prefix(Constants.Conversation.ToolClassifier.commandMaximumLength))
    }

    static func classifyScriptsContextAndSearch(_ context: ClassificationContext) -> ToolDisplay? {
        let input = context.input
        let clean = context.clean
        let infoReq = context.informationRequest
        let query = context.query
        // Script operations
        if clean.contains("script") {
            let scriptName = input["name"]?.value as? String
            if clean.contains("create") { return ToolDisplay(icon: .terminal, verb: "Create script", subject: scriptName, path: nil) }
            if clean.contains("start") || clean.contains("run") { return ToolDisplay(icon: .terminal, verb: "Run script", subject: scriptName, path: nil) }
            if clean.contains("stop") { return ToolDisplay(icon: .terminal, verb: "Stop script", subject: scriptName, path: nil) }
            if clean.contains("output") { return ToolDisplay(icon: .terminal, verb: "Script output", subject: scriptName, path: nil) }
            return ToolDisplay(icon: .terminal, verb: "Script", subject: scriptName, path: nil)
        }

        // Context engine
        if clean.contains("codebase") || clean.contains("retrieval") || clean.contains("git_commit_retrieval") || clean.contains("git-commit-retrieval") {
            let request = infoReq ?? query
            let source = clean.contains("git") || clean.contains("commit") ? "Commit History" :
                          clean.contains("conversation") ? "Conversations" : "Codebase"
            let subject = request.map { request in
                "\(source) · \(String(request.prefix(Constants.Conversation.ToolClassifier.standardSubjectMaximumLength)))"
            } ?? source
            return ToolDisplay(icon: .context, verb: "Context Engine", subject: subject, path: nil)
        }

        // Search
        if clean.contains("search") || clean.contains("grep") || clean.contains("glob") || clean.contains("find") {
            if clean.contains("web") {
                return ToolDisplay(
                    icon: .web,
                    verb: "Search web",
                    subject: query.map { query in
                        String(query.prefix(Constants.Conversation.ToolClassifier.standardSubjectMaximumLength))
                    },
                    path: nil
                )
            }
            let request = query ?? infoReq ?? (input["pattern"]?.value as? String)
            return ToolDisplay(
                icon: .search,
                verb: "Search",
                subject: request.map { request in
                    String(request.prefix(Constants.Conversation.ToolClassifier.standardSubjectMaximumLength))
                },
                path: nil
            )
        }

        return nil
    }
}

private extension ToolClassifier {
    /// Nth capture group of a case-insensitive regex match, or nil.
    /// Compiled regexes are cached by pattern (rows re-render often mid-turn).
    private static var regexCache: [String: Regex<AnyRegexOutput>] = [:]
    private static let regexCacheLock = NSLock()

    private static func firstCapture(_ pattern: String, in text: String, group: Int = 1) -> String? {
        regexCacheLock.lock()
        var regex = regexCache[pattern]
        if regex == nil {
            regex = try? Regex(pattern).ignoresCase()
            if let regex {
                regexCache[pattern] = regex
            } else {
                assertionFailure("Invalid tool-title regex pattern: \(pattern)")
            }
        }
        regexCacheLock.unlock()
        guard let regex else { return nil }
        guard group >= 0,
              let match = text.firstMatch(of: regex),
              match.output.count > group,
              let capture = match.output[group].substring else {
            return nil
        }
        return String(capture)
    }

    /// Treat a captured title fragment as a file path when it looks like one:
    /// contains "." or "/", or is a single backtick-quoted token (extensionless
    /// filenames like "Read `LICENSE`" / "Edit `Makefile`").
    private static func pathCandidate(_ captured: String) -> String? {
        let raw = captured.trimmingCharacters(in: .whitespaces)
        let wasQuoted = raw.count > 2 && raw.hasPrefix("`") && raw.hasSuffix("`")
        let candidate = raw.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        guard !candidate.isEmpty else { return nil }
        if candidate.contains(".") || candidate.contains("/") { return candidate }
        if wasQuoted, !candidate.contains(" ") { return candidate }
        return nil
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let string, !string.isEmpty else { return nil }
        return string
    }
}
