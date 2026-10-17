import Foundation

nonisolated enum ScriptMonitorMode: String, Equatable, Sendable {
    case command
    case service
}

/// Active observation metadata, separate from a script's runtime status.
nonisolated struct ScriptMonitorSummary: Equatable, Identifiable, Sendable {
    let monitorId: String
    let workspaceId: String
    let agentId: String
    let scriptId: String
    let runId: String
    let scriptName: String
    let mode: ScriptMonitorMode
    let state: String
    let createdAt: String
    let expiresAt: String
    let lineCount: Int?
    let outputPatternPreview: String?
    let outputPatternTruncated: Bool? // swiftlint:disable:this discouraged_optional_boolean

    var id: String { monitorId }
    static let previewByteLimit = 160
    static let maximumLineCount = 1_000_000
}

nonisolated extension ScriptMonitorSummary {
    init(_ value: Any, workspaceId: String) throws {
        guard let row = value as? [String: Any],
              let returnedWorkspace = row["workspaceId"] as? String,
              !workspaceId.isEmpty, returnedWorkspace.utf8.elementsEqual(workspaceId.utf8),
              row["state"] as? String == "active",
              let rawMode = row["mode"] as? String, let mode = ScriptMonitorMode(rawValue: rawMode),
              let scriptName = row["scriptName"] as? String else { throw ScriptMonitorReadError.invalidResponse }
        self.monitorId = try Self.requiredText(row, "monitorId")
        self.workspaceId = returnedWorkspace
        self.agentId = try Self.requiredText(row, "agentId")
        self.scriptId = try Self.requiredText(row, "scriptId")
        self.runId = try Self.requiredText(row, "runId")
        self.scriptName = scriptName
        self.mode = mode
        self.state = "active"
        // Preserve server text: an invalid date renders as unavailable, never a guessed deadline.
        self.createdAt = try Self.requiredText(row, "createdAt")
        self.expiresAt = try Self.requiredText(row, "expiresAt")
        self.lineCount = try Self.parseLineCount(row)
        let preview = try Self.parsePreview(row)
        self.outputPatternPreview = preview?.text
        self.outputPatternTruncated = preview?.truncated
    }

    private static func requiredText(_ row: [String: Any], _ key: String) throws -> String {
        guard let value = row[key] as? String, !value.isEmpty else { throw ScriptMonitorReadError.invalidResponse }
        return value
    }

    private static func parseLineCount(_ row: [String: Any]) throws -> Int? {
        guard let raw = row["lineCount"] else { return nil }
        guard let count = ConnectionPrincipal.number(raw), count >= 1, count <= Double(maximumLineCount),
              count.rounded(.down) == count else { throw ScriptMonitorReadError.invalidResponse }
        return Int(count)
    }

    private static func parsePreview(_ row: [String: Any]) throws -> (text: String, truncated: Bool)? {
        guard row["outputPatternPreview"] != nil || row["outputPatternTruncated"] != nil else { return nil }
        guard let text = row["outputPatternPreview"] as? String, text.utf8.count <= previewByteLimit,
              let truncated = ConnectionPrincipal.boolean(row["outputPatternTruncated"]) else { throw ScriptMonitorReadError.invalidResponse }
        return (text, truncated)
    }
}

/// Only an explicitly selected active watch loads full trigger configuration.
nonisolated struct ScriptMonitorDetail: Equatable, Sendable {
    let summary: ScriptMonitorSummary
    let outputPattern: String?
}

nonisolated extension ScriptMonitorDetail {
    init(_ value: Any, workspaceId: String, monitorId: String) throws {
        guard var row = value as? [String: Any], let returnedID = row["monitorId"] as? String,
              !monitorId.isEmpty, returnedID.utf8.elementsEqual(monitorId.utf8) else { throw ScriptMonitorReadError.invalidResponse }
        if row["outputPattern"] == nil, row["outputPatternPreview"] != nil || row["outputPatternTruncated"] != nil {
            throw ScriptMonitorReadError.invalidResponse
        }
        row.removeValue(forKey: "outputPatternPreview")
        row.removeValue(forKey: "outputPatternTruncated")
        if let raw = row["outputPattern"] {
            guard let pattern = raw as? String else { throw ScriptMonitorReadError.invalidResponse }
            outputPattern = pattern
            // Match the wire preview's UTF-8 bound without splitting a scalar or executing the regex.
            var preview = ""
            for scalar in pattern.unicodeScalars {
                let next = String(scalar)
                guard preview.utf8.count + next.utf8.count <= ScriptMonitorSummary.previewByteLimit else { break }
                preview.append(next)
            }
            row["outputPatternPreview"] = preview
            row["outputPatternTruncated"] = preview.utf8.count < pattern.utf8.count
        } else {
            outputPattern = nil
        }
        summary = try ScriptMonitorSummary(row, workspaceId: workspaceId)
    }
}
