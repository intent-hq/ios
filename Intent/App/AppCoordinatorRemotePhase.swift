import Foundation

/// How this window's Mac connection is usable after the user entered the app.
/// An ordinary drop keeps everything readable; a stopped reconnection blocks.
enum RemoteConnectionPhase: Equatable {
    case live
    case readOnly
    case stopped
}

extension AppCoordinator {
    /// `isDisconnected` records a loss after entry; the transport state says
    /// whether reconnection is still trying (read-only) or has stopped.
    var remotePhase: RemoteConnectionPhase {
        guard isDisconnected else { return .live }
        return dependencies.connection.connectionState == .disconnected ? .stopped : .readOnly
    }
    /// Change controls are disabled for every phase except live, including the
    /// background grace when no banner is shown yet.
    var isRemoteReadOnly: Bool { remotePhase != .live }
    private var showsConnectionLoss: Bool {
        currentScreen.supportsConnectionLossOverlay && isDisconnected && !connectionLossPresentation.isDeferred
    }
    /// Blocking "Can't reconnect" screen: reconnection stopped for good.
    var showsConnectionLossOverlay: Bool { showsConnectionLoss && remotePhase == .stopped }
    /// Non-blocking banner while reconnection keeps trying.
    var showsReadOnlyBanner: Bool { showsConnectionLoss && remotePhase == .readOnly }
    /// The saved name of this window's Mac, for connection copy.
    var connectionDisplayName: String? {
        guard let backendID else { return nil }
        let name = dependencies.persistence.loadConnections().first { $0.id == backendID.connectionID }?.displayName
        return name?.isEmpty == false ? name : nil
    }
}
