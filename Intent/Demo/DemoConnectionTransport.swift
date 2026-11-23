#if DEBUG
import Foundation

extension ConnectionManager {
    func connectDemo(serveFixtures: Bool) {
        connectInProcess(using: Self.makeInProcessTransport(serveFixtures: serveFixtures))
    }
}

final class DemoConnectionTransport: ConnectionRequestTransport {
    let scriptMonitors: DemoScriptMonitorFixtures?

    init(scriptMonitors: DemoScriptMonitorFixtures?) {
        self.scriptMonitors = scriptMonitors
    }

    static func make(serveFixtures: Bool, arguments: [String]) -> DemoConnectionTransport? {
        if serveFixtures {
            return DemoConnectionTransport(scriptMonitors: DemoScriptMonitorFixtures.configured(arguments: arguments))
        }
        return DemoMode.isEnabled ? DemoConnectionTransport(scriptMonitors: nil) : nil
    }

    nonisolated(unsafe) static var isDropped = false
    var principal: ConnectionPrincipal? {
        DemoMode.isEnabled && !DemoStartupConnection.isEnabled && !Self.isDropped ? .demoOwner : nil
    }

    var capabilities: ConnectionCapabilities {
        var advertised: [String: Int] = [:]
        if scriptMonitors?.supportsMonitors == true {
            advertised["scriptMonitors"] = 2
            advertised["scriptActiveLists"] = 1
        }
        if DemoFixtures.designScenario?.scenario == .goal { advertised["conversationGoal"] = 1 }
        guard !advertised.isEmpty else { return .unknown }
        return ConnectionCapabilities(hello: ["server": ["protocolVersion": "15.0", "capabilities": advertised]])
    }

    func stop() {
        scriptMonitors?.stop()
    }

    func response(for method: String, params: [String: Any], on connection: ConnectionManager) async throws -> Any {
        if DemoStartupConnection.isEnabled, connection.connectionState != .connected {
            throw ConnectionManager.notConnectedRequestError()
        }
        scriptMonitors?.startEvents(for: method, params: params) { [weak connection] event in
            guard let connection else { return }
            for handler in Array(connection.eventHandlers.values) { handler("event", event) }
        }
        if let response = try await scriptMonitors?.response(for: method, params: params) { return response }
        if let response = try DemoFailureFixtures.response(for: method, params: params) { return response }
        if let gate = DemoFixtures.responseGate(for: method, params: params) {
            try await DemoFixtures.wait(for: gate)
        }
        let response = DemoFixtures.response(for: method, params: params)
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
    var demoScriptMonitorFixtures: DemoScriptMonitorFixtures? {
        (requestTransport as? DemoConnectionTransport)?.scriptMonitors
    }
}
#endif
