#if DEBUG
import Foundation

/// Debug-only demo transport: fixture responses and scripted script-monitor
/// events. Release builds compile this out with the rest of `Intent/Demo/`.
final class DemoConnectionTransport: ConnectionRequestTransport {
    let scriptMonitors: DemoScriptMonitorFixtures?

    init(scriptMonitors: DemoScriptMonitorFixtures?) {
        self.scriptMonitors = scriptMonitors
    }

    /// `--demo-data` launches serve fixtures from every connection; an
    /// explicit fixture connection also enables scripted script monitors.
    static func make(serveFixtures: Bool, arguments: [String]) -> DemoConnectionTransport? {
        if serveFixtures {
            return DemoConnectionTransport(scriptMonitors: DemoScriptMonitorFixtures.configured(arguments: arguments))
        }
        return DemoMode.isEnabled ? DemoConnectionTransport(scriptMonitors: nil) : nil
    }

    var principal: ConnectionPrincipal? { DemoMode.isEnabled ? .demoOwner : nil }

    var capabilities: ConnectionCapabilities {
        guard scriptMonitors?.supportsMonitors == true else { return .unknown }
        return ConnectionCapabilities(hello: [
            "server": ["protocolVersion": "15.0", "capabilities": ["scriptMonitors": 2, "scriptActiveLists": 1]]
        ])
    }

    func stop() {
        scriptMonitors?.stop()
    }

    func response(for method: String, params: [String: Any], on connection: ConnectionManager) async throws -> Any {
        scriptMonitors?.startEvents(for: method, params: params) { [weak connection] event in
            guard let connection else { return }
            for handler in Array(connection.eventHandlers.values) { handler("event", event) }
        }
        if let response = try await scriptMonitors?.response(for: method, params: params) { return response }
        if let gate = DemoFixtures.responseGate(for: method, params: params) {
            try await DemoFixtures.wait(for: gate)
        }
        let response = DemoFixtures.response(for: method, params: params)
        // Routed ahead of the ack: the router buffers it until the caller
        // registers its handler, the same order a live daemon can produce.
        if let push = DemoFixtures.subscriptionPush(for: method, params: params) {
            connection.subscriptionRouter.route(push)
        }
        if let event = DemoFixtures.designScenario?.event(for: method, params: params) {
            for handler in Array(connection.eventHandlers.values) { handler("event", event) }
        }
        return response
    }
}

extension ConnectionManager {
    /// Test convenience: the scripted script-monitor fixture of the installed
    /// demo transport, if any.
    var demoScriptMonitorFixtures: DemoScriptMonitorFixtures? {
        (requestTransport as? DemoConnectionTransport)?.scriptMonitors
    }
}
#endif
