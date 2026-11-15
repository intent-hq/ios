import Combine
import Observation
import UIKit

/// Serves agent `browser.exec` reverse RPCs with tabs that run on this device (§5.9, §5.45).
///
/// The device advertises `browserExec` with `browserExecPinnedOnly`, and only to a daemon
/// that honors it, so agent traffic arrives only for workspaces pinned to this device.
/// Tabs live while the connection does: a dropped connection closes them, and the next
/// connection's `browser.syncTabs` clears their registry rows.
@MainActor
@Observable
final class AgentBrowserHost {
    static let maximumTabs = 4

    private(set) var tabs: [AgentBrowserTab] = []
    /// True while the connected daemon accepts this device as a pinned-only browser host.
    private(set) var isAvailable = false
    /// Workspaces whose agent browsing is pinned to this device, as last read or written.
    private(set) var pinnedWorkspaces: Set<String> = []
    @ObservationIgnored private let connection: any SessionConnectionManaging
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private let parking = AgentBrowserParking()

    init(connection: any SessionConnectionManaging) {
        self.connection = connection
        connection.setReverseRequestHandler { [weak self] method, params in
            guard let self else { throw ReverseRequestError.methodNotFound(method) }
            return try await serve(method: method, params: params)
        }
        connection.capabilitiesPublisher
            .removeDuplicates()
            .sink { [weak self] capabilities in
                Task { @MainActor in await self?.advertise(capabilities) }
            }
            .store(in: &cancellables)
        connection.connectionStatePublisher
            .removeDuplicates()
            .sink { [weak self] state in
                guard state != .connected else { return }
                Task { @MainActor in await self?.closeAll(report: false) }
            }
            .store(in: &cancellables)
    }

    /// The hosted tab behind a workspace browser row (`tab:<tabId>`), if this device hosts it.
    func tab(forBrowserID id: String) -> AgentBrowserTab? {
        guard id.hasPrefix("tab:") else { return nil }
        let tabId = String(id.dropFirst("tab:".count))
        return tabs.first { $0.tabId == tabId }
    }

    /// Returns a web view to the offscreen host after the UI stops showing it.
    func park(_ tab: AgentBrowserTab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        parking.park(tab.webView)
    }

    /// Pins agent browsing for `workspaceId` to this device, or clears the pin.
    func setPinned(_ pinned: Bool, workspaceId: String) async throws {
        let reply = try await connection.request(
            "workspace.setBrowserClient",
            params: ["workspaceId": workspaceId, "clientId": pinned ? PairingClientIdentity.identifier() : NSNull()]
        )
        record(reply, workspaceId: workspaceId)
    }

    func refreshPin(workspaceId: String) async {
        guard isAvailable, let reply = try? await connection.request(
            "workspace.getBrowserClient", params: ["workspaceId": workspaceId]
        ) else { return }
        record(reply, workspaceId: workspaceId)
    }

    private func record(_ reply: Any, workspaceId: String) {
        let client = (reply as? [String: Any])?["browserClient"] as? [String: Any]
        if client?["clientId"] as? String == PairingClientIdentity.identifier() {
            pinnedWorkspaces.insert(workspaceId)
        } else {
            pinnedWorkspaces.remove(workspaceId)
        }
    }

    func reset() {
        cancellables.removeAll()
        connection.setReverseRequestHandler(nil)
        Task { await closeAll(report: false) }
    }

    // MARK: - Registration

    private func advertise(_ capabilities: ConnectionCapabilities) async {
        isAvailable = capabilities.supportsAgentBrowserHosting
        guard isAvailable, connection.connectionState == .connected else { return }
        do {
            _ = try await connection.request("client.hello", params: PairingClientIdentity.parameters(browserHost: true))
            _ = try await connection.request("browser.syncTabs", params: ["tabs": tabs.map(\.registryInput)])
        } catch {
            AppLog.connection.info("[AgentBrowserHost] registration failed: \(error.localizedDescription)")
        }
    }

    private func report(_ tab: AgentBrowserTab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        let input = tab.registryInput
        Task {
            _ = try? await connection.request("browser.upsertTab", params: ["workspaceId": tab.workspaceId, "tab": input])
        }
    }

    private func closeAll(report: Bool) async {
        let closing = tabs
        tabs.removeAll()
        for tab in closing {
            await tab.close()
            if report { _ = try? await connection.request("browser.removeTab", params: ["tabId": tab.tabId]) }
        }
    }

    // MARK: - browser.exec

    private func serve(method: String, params: [String: Any]) async throws -> Any {
        guard method == "browser.exec" else { throw ReverseRequestError.methodNotFound(method) }
        guard let actions = params["actions"] as? [[String: Any]], !actions.isEmpty else {
            throw ReverseRequestError.invalidParams("browser.exec: actions must be a non-empty array of objects")
        }
        let request = AgentBrowserRequest(
            workspaceId: params["workspaceId"] as? String,
            agentId: params["agentId"] as? String,
            defaultTabId: params["tabId"] as? String
        )
        var results: [[String: Any]] = []
        for action in actions {
            results.append(await run(action, request: request))
        }
        return ["success": true, "results": results]
    }

    private func run(_ action: [String: Any], request: AgentBrowserRequest) async -> [String: Any] {
        let name = action["action"] as? String ?? ""
        do {
            let result = try await perform(name, action: action, request: request)
            return ["action": name, "success": true, "result": result]
        } catch let failure as AgentBrowserActionError {
            return failure.envelope(action: name)
        } catch {
            return AgentBrowserActionError(message: error.localizedDescription).envelope(action: name)
        }
    }

    // One switch keeps the action vocabulary readable against the desktop executor.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func perform(_ name: String, action: [String: Any], request: AgentBrowserRequest) async throws -> Any {
        let tabId = action["tabId"] as? String ?? request.defaultTabId
        switch name {
        case "listTabs":
            let scope = action["scope"] as? String ?? "all"
            let listed = tabs.filter { tab in
                guard tab.workspaceId == request.workspaceId else { return false }
                switch scope {
                case "mine": return request.agentId != nil && tab.ownerAgentId == request.agentId
                case "unclaimed": return tab.ownerAgentId == nil
                default: return true
                }
            }
            return listed.map(\.registryInput)
        case "openTab":
            return try await openTab(action, request: request)
        case "navigate":
            guard let url = action["url"] as? String else { throw AgentBrowserActionError(message: "navigate requires url") }
            let tab = try ownedTab(tabId, request: request)
            try await tab.navigate(to: url)
            return ["url": tab.address, "requestedUrl": url]
        case "closeTab":
            let tab = try ownedTab(tabId, request: request)
            tabs.removeAll { $0 === tab }
            await tab.close()
            _ = try? await connection.request("browser.removeTab", params: ["tabId": tab.tabId])
            return ["tabId": tab.tabId, "closed": true]
        case "claimTab":
            let tab = try hostedTab(tabId)
            guard let width = Self.dimension(action["width"]) else {
                throw AgentBrowserActionError(message: "claimTab requires width")
            }
            if let owner = tab.ownerAgentId, owner != request.agentId {
                throw AgentBrowserActionError.alreadyClaimed(tab: tab)
            }
            tab.ownerAgentId = request.agentId
            tab.resize(to: CGSize(width: width, height: Self.dimension(action["height"]) ?? AgentBrowserTab.defaultSize.height))
            return tab.registryInput
        case "resizeTab":
            let tab = try ownedTab(tabId, request: request)
            if let width = Self.dimension(action["width"]) {
                tab.resize(to: CGSize(width: width, height: Self.dimension(action["height"]) ?? AgentBrowserTab.defaultSize.height))
            } else {
                tab.resize(to: nil)
            }
            return tab.registryInput
        case "showTab", "focusTab":
            let tab = try ownedTab(tabId, request: request)
            tab.visibility = .visible
            report(tab)
            return ["tabId": tab.tabId, "visibility": tab.visibility.rawValue]
        case "evaluate":
            guard let expression = action["expression"] as? String else {
                throw AgentBrowserActionError(message: "evaluate requires expression")
            }
            return try await ownedTab(tabId, request: request).evaluate(expression)
        case "screenshot":
            return try await screenshot(ownedTab(tabId, request: request), workspaceId: request.workspaceId)
        case "getAccessibilityTree":
            return try await ownedTab(tabId, request: request).evaluate(AgentBrowserScripts.accessibilityTree)
        case "snapshot":
            let tab = try ownedTab(tabId, request: request)
            if action["reload"] as? Bool == true, !tab.address.isEmpty { try await tab.navigate(to: tab.address) }
            return [
                "url": tab.address,
                "title": tab.title,
                "screenshot": try await screenshot(tab, workspaceId: request.workspaceId),
                "accessibilityTree": try await tab.evaluate(AgentBrowserScripts.accessibilityTree)
            ]
        default:
            throw AgentBrowserActionError.unsupported(name)
        }
    }

    private func openTab(_ action: [String: Any], request: AgentBrowserRequest) async throws -> Any {
        guard let workspaceId = request.workspaceId else { throw AgentBrowserActionError(message: "openTab requires a workspace") }
        guard let url = action["url"] as? String else { throw AgentBrowserActionError(message: "openTab requires url") }
        if let existing = tabs.first(where: { tab in
            tab.workspaceId == workspaceId && tab.ownerAgentId == request.agentId && tab.requestedURL == url
        }) {
            return ["tabId": existing.tabId, "url": existing.address, "requestedUrl": url, "reused": true]
        }
        guard tabs.count < Self.maximumTabs else {
            throw AgentBrowserActionError(message: "This device hosts at most \(Self.maximumTabs) agent tabs. Close one with { action: \"closeTab\" } first.")
        }
        let size = Self.dimension(action["width"]).map { width in
            CGSize(width: width, height: Self.dimension(action["height"]) ?? AgentBrowserTab.defaultSize.height)
        }
        let tab = AgentBrowserTab(
            tabId: "ios-\(UUID().uuidString.lowercased())",
            workspaceId: workspaceId,
            proxy: try await connection.makeBrowserProxy(),
            ownerAgentId: request.agentId,
            ownerAgentName: nil,
            visibility: action["visible"] as? Bool == true ? .visible : .hidden,
            emulatedSize: size
        )
        tab.onChange = { [weak self] in self?.report($0) }
        tabs.append(tab)
        parking.park(tab.webView)
        _ = try await connection.request("browser.upsertTab", params: ["workspaceId": workspaceId, "tab": tab.registryInput])
        var result: [String: Any] = ["tabId": tab.tabId, "requestedUrl": url]
        do {
            try await tab.navigate(to: url)
        } catch {
            result["warning"] = "The tab opened but the page did not load: \(error.localizedDescription)"
        }
        result["url"] = tab.address
        return result
    }

    private func screenshot(_ tab: AgentBrowserTab, workspaceId: String?) async throws -> [String: Any] {
        let capture = try await tab.screenshot()
        var result: [String: Any] = [
            "width": Int(capture.size.width), "height": Int(capture.size.height), "mimeType": "image/png"
        ]
        let base64 = capture.png.base64EncodedString()
        if let workspaceId,
           let saved = try? await connection.request("note.saveAsset", params: [
               "workspaceId": workspaceId, "data": base64, "mimeType": "image/png", "originalName": "ios-screenshot.png"
           ]) as? [String: Any],
           let url = saved["url"] as? String {
            result["url"] = url
        } else {
            result["base64"] = base64
        }
        return result
    }

    private func hostedTab(_ tabId: String?) throws -> AgentBrowserTab {
        guard let tab = tabs.first(where: { $0.tabId == tabId }) ?? (tabId == nil ? tabs.first : nil) else {
            throw AgentBrowserActionError(message: "Tab \(tabId ?? "(none)") is not open on this device. Use { action: \"openTab\" } to open one.")
        }
        return tab
    }

    private func ownedTab(_ tabId: String?, request: AgentBrowserRequest) throws -> AgentBrowserTab {
        let tab = try hostedTab(tabId)
        if let agentId = request.agentId, tab.ownerAgentId != agentId {
            throw AgentBrowserActionError.notOwner(tab: tab)
        }
        return tab
    }

    private static let maximumDimension = 4096.0

    private static func dimension(_ value: Any?) -> CGFloat? {
        guard let number = value as? Double, number >= 1, number <= maximumDimension else { return nil }
        return CGFloat(number)
    }
}

private struct AgentBrowserRequest {
    let workspaceId: String?
    let agentId: String?
    let defaultTabId: String?
}

/// A per-action failure, reported inside the action envelope (never a JSON-RPC error).
struct AgentBrowserActionError: Error {
    var message: String
    var code: String?
    var ownerAgentId: String??

    func envelope(action: String) -> [String: Any] {
        var envelope: [String: Any] = ["action": action, "success": false, "error": message]
        if let code { envelope["errorCode"] = code }
        if let ownerAgentId { envelope["ownerAgentId"] = ownerAgentId ?? NSNull() }
        return envelope
    }

    static func unsupported(_ action: String) -> Self {
        Self(
            message: "The \(action) action is not available on iOS agent tabs. Pin the workspace to a desktop for it.",
            code: "unsupported-on-ios"
        )
    }

    @MainActor static func notOwner(tab: AgentBrowserTab) -> Self {
        let message = tab.ownerAgentId.map { owner in
            "Tab \(tab.tabId) is owned by agent \(owner). Agents may only manipulate tabs they own."
        } ?? "Tab \(tab.tabId) is not owned by you (it is unowned). Claim it first with { action: \"claimTab\" }."
        return Self(message: message, code: "not-owner", ownerAgentId: .some(tab.ownerAgentId))
    }

    @MainActor static func alreadyClaimed(tab: AgentBrowserTab) -> Self {
        Self(
            message: "Tab \(tab.tabId) is already claimed by agent \(tab.ownerAgentId ?? "unknown").",
            code: "already-claimed",
            ownerAgentId: .some(tab.ownerAgentId)
        )
    }
}

/// Keeps hidden agent tabs in the key window, behind the app's content, so WebKit keeps
/// painting them and snapshots succeed.
@MainActor
private final class AgentBrowserParking {
    private let container: UIView = {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }()

    func park(_ webView: UIView) {
        attachContainer()
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.frame.origin = .zero
        container.addSubview(webView)
    }

    private func attachContainer() {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        guard let window, container.window !== window else { return }
        window.insertSubview(container, at: 0)
    }
}
