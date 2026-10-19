import Combine
import Foundation

extension CreationOptionsStore {
    /// These local leases never register a daemon feed. The single session
    /// listener also invalidates idle caches, so a later view can reuse only
    /// data that has not changed while it was away.
    func retainSpecialists(consumer: UUID) {
        guard isActive else { return }
        observeSession()
        specialistCatalog.retain(consumer)
    }

    func retainCreationOptions(consumer: UUID) {
        guard isActive else { return }
        creationConsumers.insert(consumer)
        retainSpecialists(consumer: consumer)
    }

    func selectModelProvider(_ providerId: String?, consumer: UUID) {
        guard isActive else { return }
        if let previous = modelConsumers[consumer], previous != providerId {
            modelCatalogs[previous]?.release(consumer)
        }
        modelConsumers[consumer] = providerId
        if let providerId {
            observeSession()
            modelCatalog(for: providerId).retain(consumer)
        }
    }

    func useDefaultModelProvider(_ inherited: Bool, consumer: UUID) {
        guard isActive else { return }
        if inherited {
            observeSession()
            defaultModelProviderCatalog.retain(consumer)
        } else {
            defaultModelProviderCatalog.release(consumer)
        }
    }

    func releaseCatalogs(consumer: UUID) {
        creationConsumers.remove(consumer)
        cancelUninterestedCreationLoad()
        specialistCatalog.release(consumer)
        defaultModelProviderCatalog.release(consumer)
        selectModelProvider(nil, consumer: consumer)
    }

    func releaseSpecialists(consumer: UUID) { specialistCatalog.release(consumer) }

    func observeSession() {
        guard isActive else { return }
        if eventHandlerID == nil {
            eventHandlerID = connectionManager.onEvent { [weak self] _, params in self?.handleCatalogEvent(params) }
        }
        observeGlobalFeed()
        guard connectionObserver == nil else { return }
        previousConnectionState = connectionManager.connectionState
        connectionObserver = connectionManager.connectionStatePublisher.sink { [weak self] state in
            guard let self, state != previousConnectionState else { return }
            let wasConnected = previousConnectionState == .connected
            previousConnectionState = state
            if wasConnected || state == .connected { invalidateCatalogs(clear: false) }
            guard state == .connected else { return }
            if creationConsumers.isEmpty { specialistCatalog.refreshIfInterested() }
            defaultModelProviderCatalog.refreshIfInterested()
            for catalog in modelCatalogs.values { catalog.refreshIfInterested() }
            refreshCreationOptionsIfInterested()
        }
    }

    private func observeGlobalFeed() {
        guard feedObserver == nil else { return }
        observedFeedReady = connectionManager.globalSubscriptionState == .subscribed
        feedObserver = connectionManager.globalSubscriptionPublisher.sink { [weak self] state in
            guard let self else { return }
            let ready = state == .subscribed
            guard ready != observedFeedReady else { return }
            observedFeedReady = ready
            guard ready else { return }
            // Reads before this ACK cannot cover changes missed while the
            // feed was unavailable. Bump catalog revisions so even a late
            // pre-ACK response must reconcile before becoming fresh again.
            // Idle caches only expire; the initial already-ready replay and
            // repeated readiness never add reads or provider discovery.
            let refresh = connectionManager.connectionState == .connected
            specialistCatalog.invalidate(refresh: refresh)
            defaultModelProviderCatalog.invalidate(refresh: refresh)
            for catalog in modelCatalogs.values { catalog.invalidate(refresh: refresh) }
        }
    }

    private func refreshCreationOptionsIfInterested() {
        guard !creationConsumers.isEmpty else { return }
        let generation = loadGeneration
        Task { [weak self] in
            guard let self, generation == loadGeneration, !creationConsumers.isEmpty else { return }
            async let workspace: () = workspaceProviderOptions.reloadIfNeeded()
            await loadIfNeeded(consumer: creationConsumers.first)
            await workspace
        }
    }

    private func handleCatalogEvent(_ params: Any) {
        guard let envelope = params as? [String: Any] else { return }
        let event = envelope["event"] as? [String: Any] ?? envelope
        let canRefresh = connectionManager.connectionState == .connected
        switch event["type"] as? String {
        case "specialists:changed":
            // specialist.list currently has no workspace parameter. Any
            // workspace's specialist change expires this backend's roster.
            specialistCatalog.invalidate(refresh: canRefresh)
        case "settings:changed":
            guard let data = event["data"] as? [String: Any],
                  let changes = data["changes"] as? [[String: Any]] else { return }
            let paths = changes.compactMap { $0["path"] as? String }
            if paths.contains(where: { Self.affectsSpecialists($0) }) {
                specialistCatalog.invalidate(refresh: canRefresh)
            }
            if paths.contains(where: { Self.inSettingsFamily($0, "model") }) {
                defaultModelProviderCatalog.invalidate(refresh: canRefresh)
            }
            for (provider, catalog) in modelCatalogs where paths.contains(where: { Self.affectsModels($0, provider: provider) }) {
                catalog.invalidate(refresh: canRefresh)
            }
        default:
            break
        }
    }

    static func affectsSpecialists(_ path: String) -> Bool {
        inSettingsFamily(path, "specialists") || inSettingsFamily(path, "model")
    }

    static func affectsModels(_ path: String, provider: String) -> Bool {
        inSettingsFamily(path, "model") || path == "providers" || path == "providers.paths"
            || inSettingsFamily(path, "providers.paths.\(provider)")
            || inSettingsFamily(path, "providers.enabled")
    }

    private static func inSettingsFamily(_ path: String, _ family: String) -> Bool {
        path == family || path.hasPrefix(family + ".")
    }
}
