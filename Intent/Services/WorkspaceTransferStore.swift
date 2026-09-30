import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceTransferStore {
    private(set) var isBusy = false
    private(set) var isComplete = false
    private(set) var canCancel = false
    private(set) var errorMessage: String?
    private(set) var statusMessage = "Review the transfer before continuing."
    private(set) var progress: Double?
    private(set) var plan: WorkspaceTransferPlan?

    @ObservationIgnored private let workspaceId: String
    @ObservationIgnored private let source: any SessionConnectionManaging
    @ObservationIgnored private let makeDestination: @MainActor () -> any SessionConnectionManaging
    @ObservationIgnored private let timing: WorkspaceTransferTiming
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var relay: WorkspaceTransferRelay?

    init(
        workspaceId: String,
        source: any SessionConnectionManaging,
        makeDestination: @escaping @MainActor () -> any SessionConnectionManaging = { ConnectionManager() },
        timing: WorkspaceTransferTiming = WorkspaceTransferTiming()
    ) {
        self.workspaceId = workspaceId
        self.source = source
        self.makeDestination = makeDestination
        self.timing = timing
    }

    func loadPlan() async {
        guard !isBusy, !isComplete else { return }
        begin(message: "Loading transfer preview…")
        plan = nil
        let task = Task {
            defer { self.finish() }
            do {
                guard self.source.connectionState == .connected,
                      try await self.source.confirmedPrincipal().isOwner else {
                    throw WorkspaceTransferError.message("Connect as the workspace owner to transfer this workspace.")
                }
                let response = try await self.source.request("workspace.transfer.plan", params: [
                    "workspaceId": self.workspaceId
                ], timeout: self.timing.request)
                try Task.checkCancellation()
                self.plan = try WorkspaceTransferPlan(response: response, workspaceId: self.workspaceId)
                self.statusMessage = "Review the transfer before continuing."
            } catch is CancellationError {
                self.statusMessage = "Transfer preview cancelled."
            } catch {
                self.errorMessage = "Transfer preview unavailable. The host may need an update. " + error.localizedDescription
                self.statusMessage = "Could not load the transfer preview."
            }
        }
        operation = task
        await awaitOperation(task)
    }

    func transfer(to destination: StoredConnection, archiveSource: Bool) async {
        guard !isBusy, !isComplete else { return }
        guard plan != nil else {
            errorMessage = "Load the transfer preview before transferring the workspace."
            return
        }
        begin(message: "Checking the destination…")
        let relay = WorkspaceTransferRelay(workspaceId: workspaceId, source: source, target: makeDestination(), timing: timing) { [weak self] message, progress, canCancel in
            self?.statusMessage = message
            self?.progress = progress
            self?.canCancel = canCancel
        }
        self.relay = relay
        // This owned task survives a view task's cancellation during commit.
        let task = Task {
            defer { self.finish() }
            do {
                self.errorMessage = try await relay.run(destination: destination, archiveSource: archiveSource)
                self.isComplete = true
                self.progress = 1
                self.statusMessage = "Workspace transferred."
            } catch is CancellationError {
                self.statusMessage = "Transfer cancelled. The source workspace is still available; stopped agents can be restarted there."
            } catch {
                self.errorMessage = error.localizedDescription
                self.statusMessage = "The transfer could not finish."
            }
        }
        operation = task
        await awaitOperation(task)
    }

    func cancel() {
        guard isBusy, canCancel else { return }
        canCancel = false
        statusMessage = "Cancelling the transfer…"
        if let relay { relay.cancel() } else { operation?.cancel() }
    }

    private func awaitOperation(_ task: Task<Void, Never>) async {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    private func begin(message: String) {
        isBusy = true
        canCancel = true
        errorMessage = nil
        progress = nil
        statusMessage = message
    }

    private func finish() {
        relay = nil
        operation = nil
        isBusy = false
        canCancel = false
    }
}
