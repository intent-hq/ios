import SwiftUI

struct ToolCallView: View {
    let block: ContentBlock
    let toolResult: ContentBlock?
    @Environment(\.colorScheme) var colorScheme
    @State private var isExpanded = false

    private var toolName: String {
        block.resolvedName ?? "tool"
    }

    private var hasError: Bool {
        toolResult?.resolvedIsError == true
    }

    // MARK: - Tool Classification

    private struct ToolDisplay {
        let icon: String
        let verb: String
        let subject: String?
        let path: String?
    }

    private var classified: ToolDisplay {
        classifyTool(name: toolName, input: block.input)
    }

    private func cleanToolName(_ name: String) -> String {
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

    private func classifyTool(name: String, input: [String: AnyCodable]?) -> ToolDisplay {
        let clean = cleanToolName(name).lowercased()
        let input = input ?? [:]
        let pathVal = input["path"]?.value as? String
        let filePath = input["file_path"]?.value as? String
        let p = pathVal ?? filePath
        let command = input["command"]?.value as? String
        let query = input["query"]?.value as? String
        let infoReq = input["information_request"]?.value as? String
        let url = input["url"]?.value as? String

        // File read
        if (clean.contains("view") || clean.contains("read")) && p != nil
            && !clean.contains("terminal") && !clean.contains("process")
            && !clean.contains("agent") && !clean.contains("note") {
            let isDir = (input["type"]?.value as? String) == "directory"
            let hasSearch = input["search_query_regex"]?.value as? String != nil
            let verb = hasSearch ? "Search" : isDir ? "List" : "Read"
            return ToolDisplay(icon: "📄", verb: verb, subject: filename(p!), path: dirname(p!))
        }

        // File write/edit
        if (clean.contains("edit") || clean.contains("str-replace") || clean.contains("str_replace")
            || clean.contains("save") || clean.contains("write"))
            && (p != nil || input["file_content"]?.value != nil || input["old_str_1"]?.value != nil)
            && !clean.contains("note") && !clean.contains("process") {
            let verb = (clean.contains("save") || clean.contains("write")) ? "Save" : "Edit"
            let file = p ?? ""
            return ToolDisplay(icon: "✏️", verb: verb, subject: filename(file), path: dirname(file))
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
            let cmd = command.map { String($0.split(separator: "\n").first ?? "").prefix(80) }.map(String.init)
            return ToolDisplay(icon: "▶️", verb: "Run", subject: cmd, path: nil)
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
            let subject = q != nil ? "\(source) · \(String(q!.prefix(60)))" : source
            return ToolDisplay(icon: "🧠", verb: "Context Engine", subject: subject, path: nil)
        }

        // Search
        if clean.contains("search") || clean.contains("grep") || clean.contains("glob") || clean.contains("find") {
            if clean.contains("web") {
                return ToolDisplay(icon: "🌐", verb: "Search web", subject: query.map { String($0.prefix(60)) }, path: nil)
            }
            let q = query ?? infoReq ?? (input["pattern"]?.value as? String)
            return ToolDisplay(icon: "🔍", verb: "Search", subject: q.map { String($0.prefix(60)) }, path: nil)
        }

        // GitHub API
        if clean.contains("github") {
            let method = input["method"]?.value as? String ?? "GET"
            let apiPath = pathVal
            let summary = input["summary"]?.value as? String
            let subject = apiPath != nil ? "\(method) \(String(apiPath!.prefix(50)))" : summary.map { String($0.prefix(60)) }
            return ToolDisplay(icon: "🐙", verb: "GitHub", subject: subject, path: nil)
        }

        // Linear
        if clean.contains("linear") {
            let summary = input["summary"]?.value as? String
            return ToolDisplay(icon: "🌐", verb: "Linear", subject: summary.map { String($0.prefix(60)) }, path: nil)
        }

        // Web fetch
        if clean.contains("web-fetch") || clean.contains("web_fetch") || clean == "fetch" {
            let subject = url.map { String($0.prefix(60)) }
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
                return ToolDisplay(icon: "🤖", verb: "Create agent", subject: agentName.map { String($0.prefix(30)) }, path: nil)
            }
            if clean.contains("delegate") {
                let taskText = input["taskText"]?.value as? String ?? input["taskDescription"]?.value as? String ?? "task"
                return ToolDisplay(icon: "🤖", verb: "Delegate", subject: String(taskText.prefix(40)), path: nil)
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
            let displayTitle = title == "spec" ? "Spec" : title.map { String($0.prefix(25)) }
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
                return ToolDisplay(icon: "📁", verb: "Rename agent", subject: agentName.map { String($0.prefix(30)) }, path: nil)
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
            if clean.contains("commit") { return ToolDisplay(icon: "📦", verb: "Commit", subject: (input["message"]?.value as? String).map { String($0.prefix(40)) }, path: nil) }
            if clean.contains("stage") { return ToolDisplay(icon: "📦", verb: "Stage", subject: nil, path: nil) }
            return ToolDisplay(icon: "📦", verb: "Git", subject: nil, path: nil)
        }

        // Generic fallback: use tool name as verb, first meaningful input as subject
        let fallbackSubject = (pathVal ?? query ?? infoReq ?? command ?? url).map { String($0.prefix(50)) }
        let cleanedName = cleanToolName(name)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
        return ToolDisplay(icon: "🔧", verb: cleanedName, subject: fallbackSubject, path: nil)
    }

    private func filename(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.last.map(String.init) ?? path
    }

    private func dirname(_ path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return nil }
        return parts.dropLast().joined(separator: "/")
    }

    // MARK: - Border Color (status indicator)

    private var borderColor: Color {
        if toolResult == nil { return Color.blue }
        return hasError ? Theme.destructive(for: colorScheme) : Color.green.opacity(0.5)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Compact single-line header
            Button { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } } label: {
                HStack(spacing: 4) {
                    Text(classified.icon)
                        .font(.caption2)
                    Text(classified.verb)
                        .font(.caption)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    if let subject = classified.subject {
                        Text(subject)
                            .font(.caption)
                            .foregroundStyle(Theme.foreground(for: colorScheme))
                            .lineLimit(1)
                    }
                    if let path = classified.path {
                        Text(path)
                            .font(.caption2)
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(0.6))
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(0.4))
                }
                .padding(.leading, 8)
                .padding(.vertical, 3)
            }
            .buttonStyle(.plain)

            if isExpanded {
                expandedContent
            }
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(borderColor)
                .frame(width: 2)
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let input = block.input, !input.isEmpty {
                Text("Input")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(formatJSON(input))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                }
            }
            if let result = toolResult {
                Divider()
                Text(hasError ? "Error" : "Result")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(hasError
                        ? Theme.destructive(for: colorScheme)
                        : Theme.mutedForeground(for: colorScheme))
                if let output = result.output {
                    ScrollView {
                        Text(String(describing: output.value).prefix(2000))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Theme.foreground(for: colorScheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private func formatJSON(_ dict: [String: AnyCodable]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict.mapValues { $0.value },
            options: [.prettyPrinted, .sortedKeys]
        ), let str = String(data: data, encoding: .utf8) else {
            return String(describing: dict)
        }
        return str
    }
}

