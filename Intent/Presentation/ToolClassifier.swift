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
        var cleanedName = name
        // Strip MCP prefixes
        if let range = cleanedName.range(of: #"^mcp__[^_]+__"#, options: .regularExpression) {
            cleanedName = String(cleanedName[range.upperBound...])
        }
        // Strip common suffixes
        for suffix in ["_workspace-mcp", "-workspace-mcp"] where cleanedName.hasSuffix(suffix) {
            cleanedName = String(cleanedName.dropLast(suffix.count))
        }
        return cleanedName
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
        return trimmed.split { $0.isWhitespace }.count
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

extension ToolClassifier {
    static func classifyServices(_ context: ClassificationContext) -> ToolDisplay? {
        let input = context.input
        let clean = context.clean
        let pathVal = context.pathValue
        let url = context.url
        // GitHub API
        if clean.contains("github") {
            let method = input["method"]?.value as? String ?? "GET"
            let apiPath = pathVal
            let summary = input["summary"]?.value as? String
            let subject = apiPath.map { apiPath in
                "\(method) \(String(apiPath.prefix(Constants.Conversation.ToolClassifier.compactSubjectMaximumLength)))"
            } ?? summary.map { summary in
                String(summary.prefix(Constants.Conversation.ToolClassifier.standardSubjectMaximumLength))
            }
            return ToolDisplay(icon: "🐙", verb: "GitHub", subject: subject, path: nil)
        }

        // Linear
        if clean.contains("linear") {
            let summary = input["summary"]?.value as? String
            return ToolDisplay(
                icon: "🌐",
                verb: "Linear",
                subject: summary.map { summary in
                    String(summary.prefix(Constants.Conversation.ToolClassifier.standardSubjectMaximumLength))
                },
                path: nil
            )
        }

        // Web fetch
        if clean.contains("web-fetch") || clean.contains("web_fetch") || clean == "fetch" {
            let subject = url.map { url in
                String(url.prefix(Constants.Conversation.ToolClassifier.standardSubjectMaximumLength))
            }
            return ToolDisplay(icon: "🌐", verb: "Fetch", subject: subject, path: nil)
        }

        // Browser
        if clean.contains("browser") || clean.contains("screenshot") || clean.contains("snapshot") {
            return ToolDisplay(icon: "🖥️", verb: "Browser", subject: nil, path: nil)
        }

        return nil
    }
}

extension ToolClassifier {
    static func classifyAgents(_ context: ClassificationContext) -> ToolDisplay? {
        let input = context.input
        let clean = context.clean
        // Agent operations
        if clean.contains("agent") || clean.contains("delegate") || (clean.contains("report") && clean.contains("parent")) {
            if clean.contains("create") {
                let agentName = input["name"]?.value as? String
                return ToolDisplay(
                    icon: "🤖",
                    verb: "Create agent",
                    subject: agentName.map { agentName in
                        String(agentName.prefix(Constants.Conversation.ToolClassifier.agentNameMaximumLength))
                    },
                    path: nil
                )
            }
            if clean.contains("delegate") {
                let taskText = input["taskText"]?.value as? String ?? input["taskDescription"]?.value as? String ?? "task"
                return ToolDisplay(
                    icon: "🤖",
                    verb: "Delegate",
                    subject: String(taskText.prefix(Constants.Conversation.ToolClassifier.taskMaximumLength)),
                    path: nil
                )
            }
            if clean.contains("message") || clean.contains("send") {
                return ToolDisplay(icon: "🤖", verb: "Message agent", subject: nil, path: nil)
            }
            if clean.contains("report"), clean.contains("parent") {
                return ToolDisplay(icon: "🤖", verb: "Report to parent", subject: nil, path: nil)
            }
            if clean.contains("list") { return ToolDisplay(icon: "🤖", verb: "List agents", subject: nil, path: nil) }
            if clean.contains("summary") || clean.contains("status") { return ToolDisplay(icon: "🤖", verb: "Agent status", subject: nil, path: nil) }
            return ToolDisplay(icon: "🤖", verb: "Agent", subject: nil, path: nil)
        }

        return nil
    }
}

extension ToolClassifier {
    static func classifyNotesAndWorkspace(_ context: ClassificationContext) -> ToolDisplay? {
        let input = context.input
        let clean = context.clean
        guard clean.contains("note") || clean.contains("workspace") || clean.contains("timeline") else {
            return nil
        }
        let title = input["title"]?.value as? String ?? input["noteId"]?.value as? String
        let displayTitle = title == "spec"
            ? "Spec"
            : title.map { title in
                String(title.prefix(Constants.Conversation.ToolClassifier.noteTitleMaximumLength))
            }
        if let display = classifyPrimaryNoteOperation(clean: clean, displayTitle: displayTitle) {
            return display
        }
        return classifySecondaryNoteOperation(input: input, clean: clean, displayTitle: displayTitle)
    }

    static func classifyPrimaryNoteOperation(clean: String, displayTitle: String?) -> ToolDisplay? {
            if clean.contains("create"), clean.contains("note") { return ToolDisplay(icon: "📝", verb: "Create note", subject: displayTitle, path: nil) }
            if clean.contains("read"), clean.contains("note") { return ToolDisplay(icon: "📝", verb: "Read note", subject: displayTitle, path: nil) }
            if clean.contains("edit"), clean.contains("note") { return ToolDisplay(icon: "📝", verb: "Edit note", subject: displayTitle, path: nil) }
            if clean.contains("add"), clean.contains("note") { return ToolDisplay(icon: "📝", verb: "Add to note", subject: displayTitle, path: nil) }
            if clean.contains("set"), clean.contains("content") { return ToolDisplay(icon: "📝", verb: "Replace note", subject: displayTitle, path: nil) }
            if clean.contains("delete"), clean.contains("note") { return ToolDisplay(icon: "📝", verb: "Delete note", subject: displayTitle, path: nil) }
            if clean.contains("list"), clean.contains("note") { return ToolDisplay(icon: "📝", verb: "List notes", subject: nil, path: nil) }
            if clean.contains("comment") { return ToolDisplay(icon: "📝", verb: "Comment", subject: displayTitle, path: nil) }
        return nil
    }

    static func classifySecondaryNoteOperation(
        input: [String: AnyCodable],
        clean: String,
        displayTitle: String?
    ) -> ToolDisplay {
            if clean.contains("task"), clean.contains("status") {
                let status = input["status"]?.value as? String
                let subject = displayTitle.flatMap { title in
                    status.map { "\(title) → \($0)" }
                } ?? displayTitle
                return ToolDisplay(icon: "📋", verb: "Update task", subject: subject, path: nil)
            }
            if clean.contains("title") || clean.contains("rename") { return ToolDisplay(icon: "📁", verb: "Rename", subject: displayTitle, path: nil) }
            if clean.contains("timeline") { return ToolDisplay(icon: "📁", verb: "Timeline", subject: nil, path: nil) }
            if clean.contains("name"), clean.contains("agent") {
                let agentName = input["name"]?.value as? String
                return ToolDisplay(
                    icon: "📁",
                    verb: "Rename agent",
                    subject: agentName.map { agentName in
                        String(agentName.prefix(Constants.Conversation.ToolClassifier.agentNameMaximumLength))
                    },
                    path: nil
                )
            }
            return ToolDisplay(icon: "📁", verb: "Workspace", subject: displayTitle, path: nil)
    }
}

extension ToolClassifier {
    static func classifyTasksAndGit(_ context: ClassificationContext) -> ToolDisplay? {
        let input = context.input
        let clean = context.clean
        // Task operations
        if clean.contains("task") {
            if clean.contains("view") || clean.contains("list") { return ToolDisplay(icon: "📋", verb: "View", subject: "task list", path: nil) }
            if clean.contains("add") { return ToolDisplay(icon: "📋", verb: "Add", subject: "task", path: nil) }
            if clean.contains("update") { return ToolDisplay(icon: "📋", verb: "Update", subject: "task", path: nil) }
            if clean.contains("get"), clean.contains("my") { return ToolDisplay(icon: "📋", verb: "Get task", subject: nil, path: nil) }
            return ToolDisplay(icon: "📋", verb: "Task", subject: nil, path: nil)
        }

        // Git operations
        if clean.contains("git") || clean.contains("commit") || clean.contains("stage") || clean.contains("merge") {
            if clean.contains("status") { return ToolDisplay(icon: "📦", verb: "Git status", subject: nil, path: nil) }
            if clean.contains("commit") {
                return ToolDisplay(
                    icon: "📦",
                    verb: "Commit",
                    subject: (input["message"]?.value as? String).map { message in
                        String(message.prefix(Constants.Conversation.ToolClassifier.commitMessageMaximumLength))
                    },
                    path: nil
                )
            }
            if clean.contains("stage") { return ToolDisplay(icon: "📦", verb: "Stage", subject: nil, path: nil) }
            return ToolDisplay(icon: "📦", verb: "Git", subject: nil, path: nil)
        }

        return nil
    }
}

extension ToolClassifier {
    static func classifyFallback(_ context: ClassificationContext) -> ToolDisplay {
        let input = context.input
        let clean = context.clean
        let acpTitle = context.acpTitle
        let pathVal = context.pathValue
        let query = context.query
        let infoReq = context.informationRequest
        let command = context.command
        let url = context.url
        let name = context.name
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
                path: nil
            )
        }

        // Generic fallback: use tool name as verb, first meaningful input as subject
        let fallbackSubject = (pathVal ?? query ?? infoReq ?? command ?? url).map { subject in
            String(subject.prefix(Constants.Conversation.ToolClassifier.compactSubjectMaximumLength))
        }
        let cleanedName = cleanToolName(name)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { component in component.prefix(1).uppercased() + component.dropFirst().lowercased() }
            .joined(separator: " ")
        return ToolDisplay(icon: "🔧", verb: cleanedName, subject: fallbackSubject, path: nil)
    }
}
