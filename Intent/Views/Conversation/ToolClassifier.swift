import Foundation

/// Classifies a tool_use block into a compact display (icon + verb + subject)
/// for the conversation tool rows. Extracted from ToolCallView so the
/// classification path is unit-testable.
enum ToolClassifier {

    struct ToolDisplay {
        let icon: String
        let verb: String
        let subject: String?
        let path: String?
    }

    static func cleanToolName(_ name: String) -> String {
        var n = name
        // Strip MCP prefixes
        if let range = n.range(of: #"^mcp__[^_]+__"#, options: .regularExpression) {
            n = String(n[range.upperBound...])
        }
        // Strip common suffixes
        for suffix in ["_workspace-mcp", "-workspace-mcp"] {
            if n.hasSuffix(suffix) { n = String(n.dropLast(suffix.count)) }
        }
        return n
    }

    static func classify(name: String, input: [String: AnyCodable]?) -> ToolDisplay {
        let clean = cleanToolName(name).lowercased()
        let input = input ?? [:]
        let pathVal = input["path"]?.value as? String
        let filePath = input["file_path"]?.value as? String
        let p = pathVal ?? filePath
        let command = input["command"]?.value as? String
        let query = input["query"]?.value as? String
        let infoReq = input["information_request"]?.value as? String
        let url = input["url"]?.value as? String
        // ACP human-readable title echoed by the daemon (input._acpTitle) —
        // often the ONLY input available mid-turn (providers send raw_input: null).
        let acpTitle = nonEmpty((input["_acpTitle"]?.value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines))

        // workspace_api: prefer human-readable label over the raw tool name
        // (detected by name, or by input shape: code + summary)
        let summary = nonEmpty((input["summary"]?.value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines))
        if clean == "workspace_api"
            || (input["code"]?.value as? String != nil && summary != nil) {
            let titleIsRawName = acpTitle == nil
                || cleanToolName(acpTitle!).lowercased() == "workspace_api"
            if let label = titleIsRawName ? (summary ?? acpTitle) : (acpTitle ?? summary) {
                return ToolDisplay(
                    icon: "📁",
                    verb: String(label.prefix(Constants.Conversation.ToolClassifier.titleMaximumLength)),
                    subject: nil,
                    path: nil)
            }
        }

        // File read
        if (clean.contains("view") || clean.contains("read"))
            && !clean.contains("terminal") && !clean.contains("process")
            && !clean.contains("agent") && !clean.contains("note") {
            let isDir = (input["type"]?.value as? String) == "directory"
            if let p = p {
                let hasSearch = input["search_query_regex"]?.value as? String != nil
                let verb = hasSearch ? "Search" : isDir ? "List" : "Read"
                return ToolDisplay(icon: "📄", verb: verb, subject: filename(p), path: dirname(p))
            }
            // _acpTitle fallback: extract the path from e.g. "Read `src/foo.rs`"
            // (no end anchor: multi-line titles match on the first line, like desktop)
            if let title = acpTitle,
               let captured = firstCapture(#"^(?:Read|View|List\s+Contents?)\s+(.+)"#, in: title),
               let candidate = pathCandidate(captured) {
                let titleIsDir = isDir
                    || title.range(of: #"^List\s+Contents?"#,
                                   options: [.regularExpression, .caseInsensitive]) != nil
                return ToolDisplay(icon: "📄", verb: titleIsDir ? "List" : "Read",
                                   subject: filename(candidate), path: dirname(candidate))
            }
        }

        // File write/edit
        if (clean.contains("edit") || clean.contains("str-replace") || clean.contains("str_replace")
            || clean.contains("save") || clean.contains("write"))
            && !clean.contains("note") && !clean.contains("process") {
            let verb = (clean.contains("save") || clean.contains("write")) ? "Save" : "Edit"
            if p != nil || input["file_content"]?.value != nil || input["old_str_1"]?.value != nil {
                let file = p ?? ""
                return ToolDisplay(icon: "✏️", verb: verb, subject: filename(file), path: dirname(file))
            }
            // _acpTitle fallback: extract the path from e.g. "Edit `src/foo.ts`"
            if let title = acpTitle,
               let captured = firstCapture(#"^(?:Edit|Save|Read|Write|Delete|View|Create)\s+(.+)"#, in: title),
               let candidate = pathCandidate(captured) {
                return ToolDisplay(icon: "✏️", verb: verb,
                                   subject: filename(candidate), path: dirname(candidate))
            }
        }

        // File delete
        if (clean.contains("remove") || clean.contains("delete")) && !clean.contains("note") && !clean.contains("comment") {
            if let paths = input["file_paths"]?.value as? [Any], !paths.isEmpty {
                if paths.count == 1, let first = paths[0] as? String {
                    return ToolDisplay(icon: "🗑️", verb: "Delete", subject: filename(first), path: dirname(first))
                }
                return ToolDisplay(icon: "🗑️", verb: "Delete", subject: "\(paths.count) files", path: nil)
            }
            if let p = p {
                return ToolDisplay(icon: "🗑️", verb: "Delete", subject: filename(p), path: dirname(p))
            }
        }

        // Terminal/process
        if clean.contains("process") || clean.contains("terminal") || clean.contains("bash")
            || clean.contains("shell") || clean == "run" || clean.hasPrefix("run ")
            || clean == "launch" || clean.hasPrefix("launch ") || command != nil {
            if clean.contains("read") { return ToolDisplay(icon: "▶️", verb: "Read", subject: "terminal", path: nil) }
            if clean.contains("write") { return ToolDisplay(icon: "▶️", verb: "Write to", subject: "terminal", path: nil) }
            if clean.contains("kill") { return ToolDisplay(icon: "▶️", verb: "Kill", subject: "terminal", path: nil) }
            if clean.contains("list") { return ToolDisplay(icon: "▶️", verb: "List", subject: "processes", path: nil) }
            var verb = "Run"
            var cmd = command.map {
                String($0.split(separator: "\n").first ?? "")
                    .prefix(Constants.Conversation.ToolClassifier.commandMaximumLength)
            }.map(String.init)
            if cmd == nil, let title = acpTitle {
                // _acpTitle fallback: extract the verb/command from e.g. "Run `cargo test`",
                // "Kill terminal 5", "Launch `pnpm dev`" (desktop parity)
                let pattern = #"^(Run|Launch|Read|List|Kill|Write)\s+`?(.+?)`?\s*$"#
                if let titleVerb = firstCapture(pattern, in: title, group: 1)?.lowercased(),
                   let rest = firstCapture(pattern, in: title, group: 2)?
                       .trimmingCharacters(in: .whitespaces),
                   !rest.isEmpty {
                    switch titleVerb {
                    case "list": verb = "List"; cmd = rest
                    case "read": verb = "Read"; cmd = rest
                    case "kill": verb = "Kill"; cmd = rest
                    case "write": verb = "Write to"; cmd = rest
                    case "launch":
                        verb = "Launch"
                        cmd = String(String(rest.split(separator: "\n").first ?? "")
                            .prefix(Constants.Conversation.ToolClassifier.commandMaximumLength))
                    default:
                        cmd = String(String(rest.split(separator: "\n").first ?? "")
                            .prefix(Constants.Conversation.ToolClassifier.commandMaximumLength))
                    }
                }
            }
            return ToolDisplay(icon: "▶️", verb: verb, subject: cmd, path: nil)
        }

        // Script operations
        if clean.contains("script") {
            let scriptName = input["name"]?.value as? String
            if clean.contains("create") { return ToolDisplay(icon: "▶️", verb: "Create script", subject: scriptName, path: nil) }
            if clean.contains("start") || clean.contains("run") { return ToolDisplay(icon: "▶️", verb: "Run script", subject: scriptName, path: nil) }
            if clean.contains("stop") { return ToolDisplay(icon: "▶️", verb: "Stop script", subject: scriptName, path: nil) }
            if clean.contains("output") { return ToolDisplay(icon: "▶️", verb: "Script output", subject: scriptName, path: nil) }
            return ToolDisplay(icon: "▶️", verb: "Script", subject: scriptName, path: nil)
        }

        // Context engine
        if clean.contains("codebase") || clean.contains("retrieval") || clean.contains("git_commit_retrieval") || clean.contains("git-commit-retrieval") {
            let q = infoReq ?? query
            let source = clean.contains("git") || clean.contains("commit") ? "Commit History" :
                          clean.contains("conversation") ? "Conversations" : "Codebase"
            let subject = q != nil
                ? "\(source) · \(String(q!.prefix(Constants.Conversation.ToolClassifier.standardSubjectMaximumLength)))"
                : source
            return ToolDisplay(icon: "🧠", verb: "Context Engine", subject: subject, path: nil)
        }

        // Search
        if clean.contains("search") || clean.contains("grep") || clean.contains("glob") || clean.contains("find") {
            if clean.contains("web") {
                return ToolDisplay(
                    icon: "🌐",
                    verb: "Search web",
                    subject: query.map {
                        String($0.prefix(Constants.Conversation.ToolClassifier.standardSubjectMaximumLength))
                    },
                    path: nil)
            }
            let q = query ?? infoReq ?? (input["pattern"]?.value as? String)
            return ToolDisplay(
                icon: "🔍",
                verb: "Search",
                subject: q.map {
                    String($0.prefix(Constants.Conversation.ToolClassifier.standardSubjectMaximumLength))
                },
                path: nil)
        }

        // GitHub API
        if clean.contains("github") {
            let method = input["method"]?.value as? String ?? "GET"
            let apiPath = pathVal
            let summary = input["summary"]?.value as? String
            let subject = apiPath != nil
                ? "\(method) \(String(apiPath!.prefix(Constants.Conversation.ToolClassifier.compactSubjectMaximumLength)))"
                : summary.map {
                    String($0.prefix(Constants.Conversation.ToolClassifier.standardSubjectMaximumLength))
                }
            return ToolDisplay(icon: "🐙", verb: "GitHub", subject: subject, path: nil)
        }

        // Linear
        if clean.contains("linear") {
            let summary = input["summary"]?.value as? String
            return ToolDisplay(
                icon: "🌐",
                verb: "Linear",
                subject: summary.map {
                    String($0.prefix(Constants.Conversation.ToolClassifier.standardSubjectMaximumLength))
                },
                path: nil)
        }

        // Web fetch
        if clean.contains("web-fetch") || clean.contains("web_fetch") || clean == "fetch" {
            let subject = url.map {
                String($0.prefix(Constants.Conversation.ToolClassifier.standardSubjectMaximumLength))
            }
            return ToolDisplay(icon: "🌐", verb: "Fetch", subject: subject, path: nil)
        }

        // Browser
        if clean.contains("browser") || clean.contains("screenshot") || clean.contains("snapshot") {
            return ToolDisplay(icon: "🖥️", verb: "Browser", subject: nil, path: nil)
        }

        // Agent operations
        if clean.contains("agent") || clean.contains("delegate") || (clean.contains("report") && clean.contains("parent")) {
            if clean.contains("create") {
                let agentName = input["name"]?.value as? String
                return ToolDisplay(
                    icon: "🤖",
                    verb: "Create agent",
                    subject: agentName.map {
                        String($0.prefix(Constants.Conversation.ToolClassifier.agentNameMaximumLength))
                    },
                    path: nil)
            }
            if clean.contains("delegate") {
                let taskText = input["taskText"]?.value as? String ?? input["taskDescription"]?.value as? String ?? "task"
                return ToolDisplay(
                    icon: "🤖",
                    verb: "Delegate",
                    subject: String(taskText.prefix(Constants.Conversation.ToolClassifier.taskMaximumLength)),
                    path: nil)
            }
            if clean.contains("message") || clean.contains("send") {
                return ToolDisplay(icon: "🤖", verb: "Message agent", subject: nil, path: nil)
            }
            if clean.contains("report") && clean.contains("parent") {
                return ToolDisplay(icon: "🤖", verb: "Report to parent", subject: nil, path: nil)
            }
            if clean.contains("list") { return ToolDisplay(icon: "🤖", verb: "List agents", subject: nil, path: nil) }
            if clean.contains("summary") || clean.contains("status") { return ToolDisplay(icon: "🤖", verb: "Agent status", subject: nil, path: nil) }
            return ToolDisplay(icon: "🤖", verb: "Agent", subject: nil, path: nil)
        }

        // Note/workspace operations
        if clean.contains("note") || clean.contains("workspace") || clean.contains("timeline") {
            let title = input["title"]?.value as? String ?? input["noteId"]?.value as? String
            let displayTitle = title == "spec"
                ? "Spec"
                : title.map { String($0.prefix(Constants.Conversation.ToolClassifier.noteTitleMaximumLength)) }
            if clean.contains("create") && clean.contains("note") { return ToolDisplay(icon: "📝", verb: "Create note", subject: displayTitle, path: nil) }
            if clean.contains("read") && clean.contains("note") { return ToolDisplay(icon: "📝", verb: "Read note", subject: displayTitle, path: nil) }
            if clean.contains("edit") && clean.contains("note") { return ToolDisplay(icon: "📝", verb: "Edit note", subject: displayTitle, path: nil) }
            if clean.contains("add") && clean.contains("note") { return ToolDisplay(icon: "📝", verb: "Add to note", subject: displayTitle, path: nil) }
            if clean.contains("set") && clean.contains("content") { return ToolDisplay(icon: "📝", verb: "Replace note", subject: displayTitle, path: nil) }
            if clean.contains("delete") && clean.contains("note") { return ToolDisplay(icon: "📝", verb: "Delete note", subject: displayTitle, path: nil) }
            if clean.contains("list") && clean.contains("note") { return ToolDisplay(icon: "📝", verb: "List notes", subject: nil, path: nil) }
            if clean.contains("comment") { return ToolDisplay(icon: "📝", verb: "Comment", subject: displayTitle, path: nil) }
            if clean.contains("task") && clean.contains("status") {
                let status = input["status"]?.value as? String
                let subject = displayTitle != nil && status != nil ? "\(displayTitle!) → \(status!)" : displayTitle
                return ToolDisplay(icon: "📋", verb: "Update task", subject: subject, path: nil)
            }
            if clean.contains("title") || clean.contains("rename") { return ToolDisplay(icon: "📁", verb: "Rename", subject: displayTitle, path: nil) }
            if clean.contains("timeline") { return ToolDisplay(icon: "📁", verb: "Timeline", subject: nil, path: nil) }
            if clean.contains("name") && clean.contains("agent") {
                let agentName = input["name"]?.value as? String
                return ToolDisplay(
                    icon: "📁",
                    verb: "Rename agent",
                    subject: agentName.map {
                        String($0.prefix(Constants.Conversation.ToolClassifier.agentNameMaximumLength))
                    },
                    path: nil)
            }
            return ToolDisplay(icon: "📁", verb: "Workspace", subject: displayTitle, path: nil)
        }

        // Task operations
        if clean.contains("task") {
            if clean.contains("view") || clean.contains("list") { return ToolDisplay(icon: "📋", verb: "View", subject: "task list", path: nil) }
            if clean.contains("add") { return ToolDisplay(icon: "📋", verb: "Add", subject: "task", path: nil) }
            if clean.contains("update") { return ToolDisplay(icon: "📋", verb: "Update", subject: "task", path: nil) }
            if clean.contains("get") && clean.contains("my") { return ToolDisplay(icon: "📋", verb: "Get task", subject: nil, path: nil) }
            return ToolDisplay(icon: "📋", verb: "Task", subject: nil, path: nil)
        }

        // Git operations
        if clean.contains("git") || clean.contains("commit") || clean.contains("stage") || clean.contains("merge") {
            if clean.contains("status") { return ToolDisplay(icon: "📦", verb: "Git status", subject: nil, path: nil) }
            if clean.contains("commit") {
                return ToolDisplay(
                    icon: "📦",
                    verb: "Commit",
                    subject: (input["message"]?.value as? String).map {
                        String($0.prefix(Constants.Conversation.ToolClassifier.commitMessageMaximumLength))
                    },
                    path: nil)
            }
            if clean.contains("stage") { return ToolDisplay(icon: "📦", verb: "Stage", subject: nil, path: nil) }
            return ToolDisplay(icon: "📦", verb: "Git", subject: nil, path: nil)
        }

        // Prose _acpTitle fallback: render the human-readable title verbatim
        // rather than the generic spanner row (mid-turn blocks often carry
        // ONLY the title — providers send raw_input: null). Guarded by a prose
        // check so raw tool-name-shaped titles keep the cleaned-name fallback.
        if let title = acpTitle, isProseTitle(title) {
            let lower = title.lowercased()
            let icon = lower.contains("agent") ? "🤖"
                : lower.contains("note") ? "📝"
                : lower.contains("workspace") ? "📁"
                : "🔧"
            return ToolDisplay(
                icon: icon,
                verb: String(title.prefix(Constants.Conversation.ToolClassifier.fallbackTitleMaximumLength)),
                subject: nil,
                path: nil)
        }

        // Generic fallback: use tool name as verb, first meaningful input as subject
        let fallbackSubject = (pathVal ?? query ?? infoReq ?? command ?? url).map {
            String($0.prefix(Constants.Conversation.ToolClassifier.compactSubjectMaximumLength))
        }
        let cleanedName = cleanToolName(name)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
        return ToolDisplay(icon: "🔧", verb: cleanedName, subject: fallbackSubject, path: nil)
    }

    /// Nth capture group of a case-insensitive regex match, or nil.
    /// Compiled regexes are cached by pattern (rows re-render often mid-turn).
    private static var regexCache: [String: NSRegularExpression] = [:]
    private static let regexCacheLock = NSLock()

    private static func firstCapture(_ pattern: String, in text: String, group: Int = 1) -> String? {
        regexCacheLock.lock()
        var regex = regexCache[pattern]
        if regex == nil {
            regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            if let regex = regex { regexCache[pattern] = regex }
        }
        regexCacheLock.unlock()
        guard let regex = regex else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > group,
              let captureRange = Range(match.range(at: group), in: text) else {
            return nil
        }
        return String(text[captureRange])
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
        if wasQuoted && !candidate.contains(" ") { return candidate }
        return nil
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s, !s.isEmpty else { return nil }
        return s
    }

    /// Detect prose ACP titles (human-readable, not tool identifiers): either
    /// colon-prefixed like "sub-agent-explore: Explore …" or 3+ words. Mirrors
    /// the desktop classifier's isProseToolName.
    static func isProseTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil else { return false }
        if trimmed.range(of: #"^[A-Za-z0-9._-]+:\s"#, options: .regularExpression) != nil {
            return true
        }
        return trimmed.split(whereSeparator: { $0.isWhitespace }).count
            >= Constants.Conversation.ToolClassifier.proseMinimumWordCount
    }

    static func filename(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.last.map(String.init) ?? path
    }

    static func dirname(_ path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return nil }
        return parts.dropLast().joined(separator: "/")
    }
}
