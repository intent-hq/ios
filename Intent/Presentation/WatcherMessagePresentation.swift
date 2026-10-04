import Foundation

struct WatcherMessagePresentation {
    struct Check: Equatable {
        let name: String
        let status: String

        var needsAttention: Bool {
            ["failure", "timed_out", "action_required", "startup_failure"].contains(status)
        }

        var label: String {
            switch status {
            case "success": return "Passed"
            case "failure": return "Failed"
            case "in_progress": return "Running"
            case "queued", "waiting", "pending", "requested": return "Pending"
            case "timed_out": return "Timed out"
            case "action_required": return "Action required"
            case "startup_failure": return "Could not start"
            case "": return "Status unknown"
            default: return status.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }

        var symbol: String {
            if needsAttention { return "exclamationmark.circle.fill" }
            switch status {
            case "success": return "checkmark.circle"
            case "in_progress": return "arrow.trianglehead.2.clockwise.rotate.90"
            default: return "circle.dashed"
            }
        }
    }

    let summary: String
    let checks: [Check]
    let details: String?
    let isJSON: Bool

    private static let previewCharacterLimit = 280
    private static let previewLineLimit = 4
    private static let jsonByteLimit = 262_144
    private static let candidateLimit = 16
    private static let fence = "```"

    init(text: String) {
        if let payload = Self.jsonPayload(in: text),
           let data = try? JSONSerialization.data(
               withJSONObject: payload.value,
               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
           ),
           let formatted = String(data: data, encoding: .utf8) {
            summary = payload.prefix.isEmpty ? "Watcher update" : payload.prefix
            checks = Self.checks(in: payload.value)
            details = formatted
            isJSON = true
        } else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = trimmed.components(separatedBy: .newlines)
            let isLong = trimmed.count > Self.previewCharacterLimit || lines.count > Self.previewLineLimit
            summary = isLong
                ? String(lines.prefix(Self.previewLineLimit).joined(separator: "\n").prefix(Self.previewCharacterLimit)) + "…"
                : trimmed
            checks = []
            details = isLong ? text : nil
            isJSON = false
        }
    }

    private static func jsonPayload(in text: String) -> (prefix: String, value: Any)? {
        guard text.utf8.count <= jsonByteLimit else { return nil }
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fenced = candidate.hasSuffix(fence)
        if fenced {
            candidate = String(candidate.dropLast(fence.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var attempts = 0
        for index in candidate.indices where candidate[index] == "{" || candidate[index] == "[" {
            attempts += 1
            guard attempts <= candidateLimit else { return nil }
            let suffix = String(candidate[index...])
            guard let value = try? JSONSerialization.jsonObject(with: Data(suffix.utf8)) else { continue }
            var prefix = String(candidate[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            if fenced {
                guard let marker = ["```json", "```"].first(where: { prefix.hasSuffix($0) }) else { continue }
                prefix = String(prefix.dropLast(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return (prefix, value)
        }
        return nil
    }

    private static func checks(in value: Any) -> [Check] {
        guard let object = value as? [String: Any], let jobs = object["jobs"] as? [[String: Any]] else { return [] }
        let checks = jobs.compactMap { job -> Check? in
            guard let rawName = job["name"] as? String else { return nil }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let conclusion = (job["conclusion"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let status = conclusion.isEmpty ? (job["status"] as? String ?? "") : conclusion
            return Check(name: name, status: status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        return checks.filter(\.needsAttention) + checks.filter { !$0.needsAttention }
    }
}
