import Foundation

/// The pull request detail reads (FE Home `github.pulls.get`, `.checks`,
/// `.reviews`, `.files`), parsed leniently from their wire dictionaries.
struct PullRequestDetail: Equatable {
    var body: String
    var headRef: String?
    var baseRef: String?

    init(body: String = "", headRef: String? = nil, baseRef: String? = nil) {
        self.body = body
        self.headRef = headRef
        self.baseRef = baseRef
    }

    init?(wire: [String: Any]) {
        guard wire["number"] is Int else { return nil }
        self.init(
            body: wire["body"] as? String ?? "",
            headRef: wire["headRef"] as? String,
            baseRef: wire["baseRef"] as? String
        )
    }
}

struct PullRequestCheck: Identifiable, Equatable {
    nonisolated enum State: String {
        case cancelled, failure, neutral, pending, success
    }

    let name: String
    let state: State
    let url: URL?

    var id: String { name + (url?.absoluteString ?? "") }

    init(name: String, state: State, url: URL? = nil) {
        self.name = name
        self.state = state
        self.url = url
    }

    init?(wire: [String: Any]) {
        guard let name = wire["name"] as? String else { return nil }
        self.init(
            name: name,
            state: (wire["state"] as? String).flatMap(State.init(rawValue:)) ?? .neutral,
            url: (wire["url"] as? String).flatMap(URL.init(string:))
        )
    }

    /// The collapsed checks row: the worst outcome leads ("2 Failed"), then
    /// pending, then the passed count. Nil when there are no checks.
    static func summary(_ checks: [Self]) -> (state: State, label: String)? {
        guard !checks.isEmpty else { return nil }
        let failed = checks.filter { $0.state == .failure || $0.state == .cancelled }.count
        if failed > 0 { return (.failure, "\(failed) Failed") }
        let pending = checks.filter { $0.state == .pending }.count
        if pending > 0 { return (.pending, "\(pending) Pending") }
        let passed = checks.filter { $0.state == .success }.count
        return passed > 0 ? (.success, "\(passed) Passed") : (.neutral, "\(checks.count) Neutral")
    }
}

struct PullRequestReviewer: Identifiable, Equatable {
    let login: String
    let verdict: String
    let state: String

    var id: String { login }

    /// One row per author with their latest review (the wire list is oldest
    /// first), then requested reviewers who have not reviewed yet.
    static func rows(reviews: [[String: Any]], requested: [String]) -> [Self] {
        var latest: [String: String] = [:]
        var order: [String] = []
        for review in reviews {
            guard let author = review["author"] as? String, let state = review["state"] as? String else { continue }
            if latest[author] == nil { order.append(author) }
            latest[author] = state
        }
        let reviewed = order.compactMap { login in latest[login].map { Self(login: login, verdict: verdict($0), state: $0.lowercased()) } }
        let waiting = requested.filter { latest[$0] == nil }.map { Self(login: $0, verdict: "Requested", state: "requested") }
        return reviewed + waiting
    }

    private static func verdict(_ state: String) -> String {
        switch state.lowercased() {
        case "approved": "Approved"
        case "changes_requested", "changes-requested": "Changes requested"
        case "dismissed": "Dismissed"
        case "pending": "Pending"
        default: "Commented"
        }
    }
}

struct PullRequestFile: Identifiable, Equatable {
    let filename: String
    let status: String
    let additions: Int
    let deletions: Int
    let patch: String?

    var id: String { filename }
    var path: String { filename }

    init?(wire: [String: Any]) {
        guard let filename = wire["filename"] as? String else { return nil }
        self.filename = filename
        status = wire["status"] as? String ?? "modified"
        additions = wire["additions"] as? Int ?? 0
        deletions = wire["deletions"] as? Int ?? 0
        patch = wire["patch"] as? String
    }
}

extension PullRequestFile: @MainActor ChangeTreeFile {}

extension WorkspaceDiffBuilder {
    /// Hunks of a GitHub file `patch` (unified diff hunks without file headers).
    nonisolated static func hunks(patch: String) -> [WorkspaceDiffHunk] {
        var hunks: [WorkspaceDiffHunk] = []
        var header: (oldStart: Int, oldLines: Int, newStart: Int, newLines: Int)?
        var lines: [WorkspaceDiffLine] = []
        var oldLine = 0
        var newLine = 0
        func flush() {
            guard let header else { return }
            hunks.append(WorkspaceDiffHunk(
                oldStart: header.oldStart, oldLines: header.oldLines,
                newStart: header.newStart, newLines: header.newLines, lines: lines
            ))
        }
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(raw)
            if text.hasPrefix("@@") {
                flush()
                lines = []
                header = hunkHeader(text)
                oldLine = header?.oldStart ?? 0
                newLine = header?.newStart ?? 0
                continue
            }
            guard header != nil, let marker = text.first else { continue }
            let content = String(text.dropFirst())
            switch marker {
            case "+":
                lines.append(WorkspaceDiffLine(type: .addition, content: content, oldNumber: nil, newNumber: newLine))
                newLine += 1
            case "-":
                lines.append(WorkspaceDiffLine(type: .deletion, content: content, oldNumber: oldLine, newNumber: nil))
                oldLine += 1
            case " ":
                lines.append(WorkspaceDiffLine(type: .context, content: content, oldNumber: oldLine, newNumber: newLine))
                oldLine += 1
                newLine += 1
            default:
                continue
            }
        }
        flush()
        return hunks
    }

    /// `@@ -a,b +c,d @@ …`; a missing count means one line.
    private nonisolated static func hunkHeader(_ line: String) -> (oldStart: Int, oldLines: Int, newStart: Int, newLines: Int)? {
        let ranges = line.split(separator: " ").dropFirst().prefix(2)
        guard ranges.count == 2 else { return nil }
        func parse(_ token: Substring) -> (Int, Int)? {
            let parts = token.dropFirst().split(separator: ",")
            guard let start = parts.first.flatMap({ Int($0) }) else { return nil }
            return (start, parts.count > 1 ? Int(parts[1]) ?? 1 : 1)
        }
        guard let old = parse(ranges[ranges.startIndex]), let new = parse(ranges[ranges.index(after: ranges.startIndex)]) else { return nil }
        return (old.0, old.1, new.0, new.1)
    }
}
