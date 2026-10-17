import Combine
import Foundation
@testable import Intent
import Testing

struct ScriptMonitorCapabilitiesTests {
    static func hello(version: Any = "14.0", monitors: Any = 2, lists: Any = 1) -> [String: Any] {
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
        #expect(!ConnectionCapabilities(hello: ["server": ["protocolVersion": "14.0", "capabilities": [:]]]).supportsScriptMonitors)
    }

    @Test func protocolMustBeInTheExplicitlySupportedMajor() {
        #expect(ConnectionCapabilities(hello: Self.hello(version: "14.12")).supportsScriptMonitors)
        let invalid: [Any] = ["13.99", "15.0", "14", "14.0.0", "14.-1", "14.x", " 14.0", "14.0 ", "１４.0", true, 14, NSNull()]
        for version in invalid {
            #expect(!ConnectionCapabilities(hello: Self.hello(version: version)).supportsScriptMonitors)
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
}
