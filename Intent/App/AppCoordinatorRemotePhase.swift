import Foundation

enum RemoteConnectionPhase: Equatable {
    case live
    case readOnly
    case stopped
}

extension AppCoordinator {
    var remotePhase: RemoteConnectionPhase {
        guard isDisconnected else { return .live }
        let connection = dependencies.connection
        guard connection.connectionState == .disconnected else { return .readOnly }
        return connection.reconnectStopReason != nil || !connection.certMismatches.isEmpty ? .stopped : .readOnly
    }
    var isRemoteReadOnly: Bool { remotePhase != .live }
    private var showsConnectionLoss: Bool {
        currentScreen.supportsConnectionLossOverlay && isDisconnected && !connectionLossPresentation.isDeferred
    }
    var showsConnectionLossOverlay: Bool { showsConnectionLoss && remotePhase == .stopped }
    var showsReadOnlyBanner: Bool { showsConnectionLoss && remotePhase == .readOnly }
    var connectionDisplayName: String? {
        guard let backendID else { return nil }
        let name = dependencies.persistence.loadConnections().first { $0.id == backendID.connectionID }?.displayName
        return name?.isEmpty == false ? name : nil
    }
}
