import Foundation

/// Explicit demo-only wire fixture. Its single event pump feeds ConnectionManager's
/// normal handlers; it never mutates a store or a view and never polls a server.
@MainActor
final class DemoScriptMonitorFixtures {
    enum Scenario: String {
        case active, unsupported, retry
        case emptyOwner = "empty-owner"
        case pageRetry = "page-retry"
        case detailRetry = "detail-retry"
        case deadlineReached = "deadline-reached"
    }

    enum Action: String, CaseIterable {
        case rename, completed, triggered, expired, cancelled
    }

    static let monitorId = "demo-script-watch-owned"
    static let scriptId = "demo-script-build-check"
    static let runId = "demo-run-watched-original"
    static let originalName = "Build verification — long script name with 日本語 and accessibility context"
    static let updatedName = "Renamed verification — same watch and run"
    private static let patternRepetitions = 20
    static let fullPattern = "^(build|test) completed: " + String(repeating: "日本語のパターン", count: patternRepetitions) + " [0-9]+$"
    private static let methodNotFound = -32_601
    private static let invalidParams = -32_602
    private static let cursor = "demo-opaque-next-page"
    private static let lifetime: TimeInterval = 3600
    private static let lineCount = 25
    private static let pollInterval: Duration = .milliseconds(100)
    private static let presentationTimestamp: TimeInterval = 1_792_238_400
    private static let presentationAnchor = Date(timeIntervalSince1970: presentationTimestamp)

    let scenario: Scenario
    let directory: URL?
    let anchor: Date
    private(set) var requests: [String] = []
    private var consumed: Set<Action> = []
    private var name = originalName
    private var active = true
    private var failedList = false
    private var failedDetail = false
    private var failedPage = false
    private var eventTask: Task<Void, Never>?

    var supportsMonitors: Bool { scenario != .unsupported }

    init(scenario: Scenario, directory: URL? = nil, anchor: Date = Date()) {
        self.scenario = scenario
        self.directory = directory
        self.anchor = anchor
        recordRequests()
    }

    static func configured(arguments: [String] = ProcessInfo.processInfo.arguments) -> DemoScriptMonitorFixtures? {
        guard let scenario = requestedScenario(arguments: arguments) else { return nil }
        return DemoScriptMonitorFixtures(
            scenario: scenario,
            directory: DemoFixtures.triggerFile(from: arguments, prefix: "--demo-script-monitor-directory="),
            anchor: presentationAnchor
        )
    }

    static func configuredPresentationDate(arguments: [String] = ProcessInfo.processInfo.arguments) -> Date? {
        requestedScenario(arguments: arguments) == nil ? nil : presentationAnchor
    }

    private static func requestedScenario(arguments: [String]) -> Scenario? {
        let prefix = "--demo-script-monitors="
        guard DemoMode.demoDataRequested(by: arguments),
              let argument = arguments.last(where: { $0.hasPrefix(prefix) }) else { return nil }
        return Scenario(rawValue: String(argument.dropFirst(prefix.count)))
    }

    func response(for method: String, params: [String: Any]) async throws -> Any? {
        guard method.hasPrefix("scriptMonitor.") else { return nil }
        requests.append(method)
        recordRequests()
        guard supportsMonitors else { throw failure("Unsupported script watches", code: Self.methodNotFound) }
        guard params["workspaceId"] as? String == DemoDesignFixtures.workspaceId else {
            throw failure("Unknown workspace", code: Self.invalidParams)
        }
        switch method {
        case "scriptMonitor.list": return try await list(params: params)
        case "scriptMonitor.get":
            guard params["monitorId"] as? String == Self.monitorId, active else {
                throw failure("Watch unavailable", code: Self.invalidParams)
            }
            if scenario == .detailRetry, !failedDetail {
                failedDetail = true
                throw failure("Demo detail temporarily unavailable")
            }
            return ownedRow(full: true)
        default: throw failure("Read-only fixture rejected a mutation", code: Self.methodNotFound)
        }
    }

    private func list(params: [String: Any]) async throws -> [String: Any] {
        guard params["view"] as? String == "summary", params["state"] as? String == "active",
              params["limit"] as? Int == 100, params["agentId"] == nil else {
            throw failure("Expected one bounded workspace summary page", code: Self.invalidParams)
        }
        if scenario == .retry, !failedList {
            if let directory {
                try await DemoFixtures.wait(for: .triggerFile(directory.appendingPathComponent("list-ready")))
            }
            failedList = true
            throw failure("Demo list temporarily unavailable")
        }
        if let cursor = params["cursor"] as? String {
            guard cursor == Self.cursor else { throw failure("Unknown cursor", code: Self.invalidParams) }
            if scenario == .pageRetry, !failedPage {
                failedPage = true
                throw failure("Demo next page temporarily unavailable")
            }
            return ["view": "summary", "monitors": active ? [ownedRow(full: false)] : []]
        }
        if scenario == .emptyOwner || scenario == .pageRetry {
            return ["view": "summary", "monitors": [otherOwnerRow], "nextCursor": Self.cursor]
        }
        return ["view": "summary", "monitors": (active ? [ownedRow(full: false)] : []) + [otherOwnerRow]]
    }

    func startEvents(for method: String, params: [String: Any], deliver: @escaping @MainActor ([String: Any]) -> Void) {
        guard method == "events.subscribe",
              (params["eventTypes"] as? [String])?.contains("scriptMonitor:*") == true else { return }
        requests.append("events.subscribe:scriptMonitor")
        recordRequests()
        guard eventTask == nil, let directory else { return }
        eventTask = Task { [weak self] in
            while !Task.isCancelled {
                for action in Action.allCases where FileManager.default.fileExists(atPath: directory.appendingPathComponent(action.rawValue).path) {
                    guard let event = self?.consume(action) else { continue }
                    deliver(event)
                }
                do { try await Task.sleep(for: Self.pollInterval) } catch { return }
            }
        }
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
    }

    /// Returns the full transient lifecycle envelope, like the daemon. Tests can
    /// also drive this synchronously to verify the fixture's wire contract.
    func consume(_ action: Action) -> [String: Any]? { // swiftlint:disable:this discouraged_optional_collection
        guard active, consumed.insert(action).inserted else { return nil }
        if action == .rename { name = Self.updatedName }
        var monitor = ownedRow(full: true)
        let event = action == .rename ? "registered" : action.rawValue
        if action != .rename {
            active = false
            monitor["state"] = action.rawValue
        }
        return [
            "type": "scriptMonitor:" + event, "workspaceId": DemoDesignFixtures.workspaceId,
            "data": ["monitor": monitor]
        ]
    }

    private func ownedRow(full: Bool) -> [String: Any] {
        let expiry = scenario == .deadlineReached ? anchor.addingTimeInterval(-Self.lifetime) : anchor.addingTimeInterval(Self.lifetime)
        var row: [String: Any] = [
            "monitorId": Self.monitorId, "workspaceId": DemoDesignFixtures.workspaceId,
            "agentId": DemoDesignFixtures.agentId, "scriptId": Self.scriptId, "runId": Self.runId,
            "scriptName": name, "mode": "command", "state": "active",
            "createdAt": anchor.addingTimeInterval(-Self.lifetime).ISO8601Format(), "expiresAt": expiry.ISO8601Format(),
            "lineCount": Self.lineCount
        ]
        if full {
            row["outputPattern"] = Self.fullPattern
        } else {
            var preview = ""
            for scalar in Self.fullPattern.unicodeScalars {
                let next = String(scalar)
                guard preview.utf8.count + next.utf8.count <= ScriptMonitorSummary.previewByteLimit else { break }
                preview.append(next)
            }
            row["outputPatternPreview"] = preview
            row["outputPatternTruncated"] = true
        }
        return row
    }

    private var otherOwnerRow: [String: Any] {
        [
            "monitorId": "demo-script-watch-other-owner", "workspaceId": DemoDesignFixtures.workspaceId,
            "agentId": "demo-other-agent", "scriptId": "demo-other-script", "runId": "demo-other-run",
            "scriptName": "Other owner's service", "mode": "service", "state": "active",
            "createdAt": anchor.ISO8601Format(), "expiresAt": anchor.addingTimeInterval(Self.lifetime).ISO8601Format()
        ]
    }

    private func recordRequests() {
        guard let directory else { return }
        try? Data(requests.joined(separator: "\n").utf8).write(to: directory.appendingPathComponent("requests"), options: .atomic)
    }

    private func failure(_ message: String, code: Int = -32_000) -> NSError {
        NSError(domain: "WebSocket", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
