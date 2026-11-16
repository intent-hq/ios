import Foundation
@testable import Intent
import Testing

struct RelayLinkStateTests {
    private let machine = UUID()
    private let other = UUID()
    private let relay: URL

    init() throws {
        relay = try #require(URL(string: "https://push.intentapp.dev"))
    }

    private func linked(_ connectionId: UUID, daemon: String = "d1") -> RelayLinkState {
        var state = RelayLinkState()
        state.record(RelayLink(connectionId: connectionId, daemonId: daemon, relayURL: relay))
        return state
    }

    @Test func linksOnlyConnectedMachinesWhileEnabled() {
        let state = RelayLinkState()
        #expect(state.shouldLink(connectionId: machine, enabled: true, connected: true, declined: []))
        #expect(!state.shouldLink(connectionId: machine, enabled: false, connected: true, declined: []))
        #expect(!state.shouldLink(connectionId: machine, enabled: true, connected: false, declined: []))
        #expect(!state.shouldLink(connectionId: machine, enabled: true, connected: true, declined: [machine]))
        #expect(!linked(machine).shouldLink(connectionId: machine, enabled: true, connected: true, declined: []))
        #expect(linked(machine).shouldLink(connectionId: other, enabled: true, connected: true, declined: []))
    }

    @Test func anyLinkHandsTheActivityToTheRelay() {
        #expect(!RelayLinkState().isRelayDriven)
        var state = linked(machine)
        #expect(state.isRelayDriven)
        state.remove(connectionId: machine)
        #expect(!state.isRelayDriven)
    }

    @Test func acceptsOnlyTheIntentRelay() throws {
        #expect(RelayLinkState().accepts(relayURL: relay))
        #expect(linked(machine).accepts(relayURL: relay))
        #expect(RelayLinkState().accepts(relayURL: try #require(URL(string: "https://PUSH.intentapp.dev/"))))
        let refused = [
            "https://relay.example.com",
            "http://push.intentapp.dev",
            "https://push.intentapp.dev:8443",
            "https://push.intentapp.dev.example.com",
            "https://evil@push.intentapp.dev",
            "https://push.intentapp.dev/v1",
            "https://push.intentapp.dev?x=1",
            "https://intent-push.example.workers.dev",
            "http://127.0.0.1:8787"
        ]
        for text in refused {
            let url = try #require(URL(string: text))
            #expect(!RelayLinkState().accepts(relayURL: url), "\(text)")
            #expect(!linked(machine).accepts(relayURL: url), "\(text)")
        }
    }

    @Test func dropsSavedLinksToOtherRelays() throws {
        let defaults = try #require(UserDefaults(suiteName: "RelayLinkStateTests-\(UUID().uuidString)"))
        // The untrusted link comes first, so it would otherwise pick the relay.
        var state = RelayLinkState()
        state.links.append(RelayLink(connectionId: other, daemonId: "d2", relayURL: try #require(URL(string: "https://relay.example.com"))))
        state.record(RelayLink(connectionId: machine, daemonId: "d1", relayURL: relay))
        state.save(to: defaults)
        let loaded = RelayLinkState.load(from: defaults)
        #expect(loaded.links.map(\.connectionId) == [machine])
        #expect(loaded.relayURL == relay)
    }

    @Test func repairedMachineReplacesItsLink() {
        var state = linked(machine, daemon: "d1")
        state.record(RelayLink(connectionId: other, daemonId: "d1", relayURL: relay))
        #expect(state.links.map(\.connectionId) == [other])
        state.record(RelayLink(connectionId: machine, daemonId: "d2", relayURL: relay))
        #expect(state.links.count == 2)
    }

    @Test func removedConnectionsAreStale() {
        var state = linked(machine)
        state.record(RelayLink(connectionId: other, daemonId: "d2", relayURL: relay))
        #expect(state.staleLinks(savedConnectionIds: [machine]).map(\.connectionId) == [other])
        #expect(state.staleLinks(savedConnectionIds: [machine, other]).isEmpty)
    }

    @Test func patchesOnlyChangesAfterRegistration() {
        let device = RelayDeviceInfo(bundleId: "dev.intentapp.ios", apsEnvironment: "development", pushToken: "ab")
        #expect(RelayLinkState().devicePatch(for: device) == nil)
        var state = linked(machine)
        state.sentDevice = device
        #expect(state.devicePatch(for: device) == nil)
        var changed = device
        changed.pushToken = "cd"
        #expect(state.devicePatch(for: changed) == changed)
    }

    @Test func persistsAcrossLaunches() throws {
        let defaults = try #require(UserDefaults(suiteName: "RelayLinkStateTests-\(UUID().uuidString)"))
        #expect(RelayLinkState.load(from: defaults) == RelayLinkState())
        var state = linked(machine)
        state.sentDevice = RelayDeviceInfo(pushToStartToken: "ef")
        state.save(to: defaults)
        #expect(RelayLinkState.load(from: defaults) == state)
    }
}
