#if DEBUG
import Foundation

/// Debug-only demo transport: fixture responses and scripted script-monitor
/// events. Release builds compile this out with the rest of `Intent/Demo/`.
extension ConnectionManager {
    func configureDemoScriptMonitors(serveFixtures: Bool, arguments: [String] = LaunchOptions.current.arguments) {
        demoScriptMonitorFixtures?.stop()
        demoScriptMonitorFixtures = serveFixtures ? DemoScriptMonitorFixtures.configured(arguments: arguments) : nil
        capabilities = .unknown
        if demoScriptMonitorFixtures?.supportsMonitors == true {
            capabilities = ConnectionCapabilities(hello: [
                "server": ["protocolVersion": "15.0", "capabilities": ["scriptMonitors": 2, "scriptActiveLists": 1]]
            ])
        }
    }

    func demoResponse(for method: String, params: [String: Any]) async throws -> Any {
        demoScriptMonitorFixtures?.startEvents(for: method, params: params) { [weak self] event in
            guard let self else { return }
            for handler in Array(eventHandlers.values) { handler("event", event) }
        }
        if let response = try await demoScriptMonitorFixtures?.response(for: method, params: params) { return response }
        if let gate = DemoFixtures.responseGate(for: method, params: params) {
            try await DemoFixtures.wait(for: gate)
        }
        let response = DemoFixtures.response(for: method, params: params)
        // Routed ahead of the ack: the router buffers it until the caller
        // registers its handler, the same order a live daemon can produce.
        if let push = DemoFixtures.subscriptionPush(for: method, params: params) {
            subscriptionRouter.route(push)
        }
        if let event = DemoFixtures.designScenario?.event(for: method, params: params) {
            for handler in Array(eventHandlers.values) { handler("event", event) }
        }
        return response
    }
}
#endif
