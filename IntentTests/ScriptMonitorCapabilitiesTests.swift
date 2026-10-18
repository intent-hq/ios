import Combine
import Foundation
@testable import Intent
import Testing

struct ScriptMonitorCapabilitiesTests {
    static func hello(version: Any = ProtocolFixtures.currentProtocolVersion, monitors: Any = 2, lists: Any = 1) -> [String: Any] {
        ["server": ["protocolVersion": version, "capabilities": ["scriptMonitors": monitors, "scriptActiveLists": lists]]]
    }

    @Test func onlyExactCapabilityVersionsAreAccepted() {
        #expect(ConnectionCapabilities(hello: Self.hello()).supportsScriptMonitors)
        let invalid: [Any] = [true, false, "2", "1", 0, 3, 1.5, NSNull()]
        for value in invalid {
            #expect(!ConnectionCapabilities(hello: Self.hello(monitors: value)).supportsScriptMonitors)
            #expect(!ConnectionCapabilities(hello: Self.hello(lists: value)).supportsScriptMonitors)
        }
        #expect(!ConnectionCapabilities(hello: Self.hello(monitors: 1)).supportsScriptMonitors)
        #expect(!ConnectionCapabilities(hello: Self.hello(lists: 2)).supportsScriptMonitors)
        #expect(!ConnectionCapabilities(hello: [:]).supportsScriptMonitors)
        #expect(!ConnectionCapabilities(hello: ["server": ["protocolVersion": ProtocolFixtures.currentProtocolVersion, "capabilities": [:]]]).supportsScriptMonitors)
    }

    @Test func capabilitiesAloneGateMonitorsOnEveryProtocolVersion() {
        // intent-hq/intent#7206: a protocol-major gate hid monitors from protocol 15 daemons.
        for version in ["14.0", "14.12", "15.0", "15.3", "16.0", "99.1"] {
            #expect(ConnectionCapabilities(hello: Self.hello(version: version)).supportsScriptMonitors)
            #expect(!ConnectionCapabilities(hello: Self.hello(version: version, monitors: 1)).supportsScriptMonitors)
            #expect(!ConnectionCapabilities(hello: Self.hello(version: version, lists: 2)).supportsScriptMonitors)
        }
    }

    @Test @MainActor func routingDefaultsAreUnsupportedAndDoNotProbeTheHost() {
        let connection = FakeConnectionManager()
        let routing: any ConnectionManagerRouting = connection
        #expect(!routing.capabilities.supportsScriptMonitors)
        var observed: [ConnectionCapabilities] = []
        let observation = routing.capabilitiesPublisher.sink { observed.append($0) }
        #expect(observed == [.unknown])
        #expect(connection.requestLog.isEmpty)
        withExtendedLifetime(observation) {}
    }

    @Test @MainActor func admissionResetsCapabilitiesAcrossDisconnectAndHostReplacement() {
        let manager = ConnectionManager(persistence: .ephemeral())
        defer { manager.disconnect() }
        let supported = ConnectionHandshake(principal: .demoOwner, capabilities: ConnectionCapabilities(hello: Self.hello()))
        manager.finishIdentityAdmission(supported, token: "host-a", fingerprint: "pin-a")
        #expect(manager.capabilities.supportsScriptMonitors)
        manager.disableScriptMonitors()
        #expect(!manager.capabilities.supportsScriptMonitors)
        manager.disconnect()
        #expect(manager.capabilities == .unknown)
        manager.finishIdentityAdmission(supported, token: "host-a", fingerprint: "pin-a")
        #expect(manager.capabilities.supportsScriptMonitors)
        manager.clearPrincipal()
        #expect(manager.capabilities == .unknown)
        manager.finishIdentityAdmission(ConnectionHandshake(principal: .demoOwner, capabilities: .unknown), token: "host-b", fingerprint: "pin-b")
        #expect(!manager.capabilities.supportsScriptMonitors)
    }

    @Test @MainActor func demoCapabilitiesRequireExplicitFixtureAndResetOnExit() {
        let manager = ConnectionManager(persistence: .ephemeral())
        defer { manager.disconnect() }
        let active = ["--demo-data", "--demo-script-monitors=active"]
        manager.configureDemoScriptMonitors(serveFixtures: false, arguments: active)
        #expect(manager.demoScriptMonitorFixtures == nil)
        #expect(manager.capabilities == .unknown)
        manager.configureDemoScriptMonitors(serveFixtures: true, arguments: ["--demo-data"])
        #expect(manager.demoScriptMonitorFixtures == nil)
        manager.configureDemoScriptMonitors(serveFixtures: true, arguments: active)
        #expect(manager.demoScriptMonitorFixtures?.supportsMonitors == true)
        #expect(manager.capabilities.supportsScriptMonitors)
        manager.configureDemoScriptMonitors(serveFixtures: true, arguments: ["--demo-data", "--demo-script-monitors=unsupported"])
        #expect(manager.demoScriptMonitorFixtures?.supportsMonitors == false)
        #expect(!manager.capabilities.supportsScriptMonitors)
        manager.configureDemoScriptMonitors(serveFixtures: true, arguments: active)
        manager.disconnect()
        #expect(manager.demoScriptMonitorFixtures == nil)
        #expect(manager.capabilities == .unknown)
    }
}
