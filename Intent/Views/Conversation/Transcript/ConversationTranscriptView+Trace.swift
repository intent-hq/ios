import SwiftUI

extension ConversationTranscriptView {
    var traceContext: String {
        "visit=\(scrollState.trace.visit) workspace=\(viewModel.workspaceId) agent=\(viewModel.agentId) generation=\(scrollState.initialScrollGeneration) ownership=\(scrollState.viewportOwnershipRevision)"
    }

    func traceEvent(_ name: StaticString, _ detail: @autoclosure () -> String = "") {
        guard ConversationTrace.enabled else { return }
        ConversationTrace.emit(name, "\(traceContext) \(detail())")
    }

    func traceSnapshot(_ reason: String) {
        guard ConversationTrace.enabled else { return }
        let scrollView = scrollMomentumProxy.scrollView
        let viewport = CGRect(origin: .zero, size: scrollView?.bounds.size ?? .zero)
        let geometry = "geometry=\(String(describing: scrollMomentumProxy.restingGeometry)) bounds=\(String(describing: scrollView?.bounds)) contentSize=\(String(describing: scrollView?.contentSize))"
        let host = "host=\(scrollView.map { String(describing: ObjectIdentifier($0)) } ?? "nil") hostingRevision=\(scrollMomentumProxy.hostingRevision) window=\(scrollView?.window != nil)"
        let state = "owner=\(lifecycle.owner) endRealized=\(lifecycle.isEndRealized) initial=\(hasInitiallyScrolled) away=\(userIsScrolledAway) interacting=\(isUserInteracting)"
        traceEvent("ViewportSnapshot", "reason=\(reason) \(geometry) \(host)")
        traceEvent("ViewportState", "reason=\(reason) \(state) loading=\(viewModel.isLoading) messages=\(viewModel.filteredMessageIDs.count) \(scrollState.trace.summary(viewport: viewport))")
        scrollState.trace.emitVisibleRows(viewport: viewport, context: "\(traceContext) reason=\(reason)")
    }

    func beginViewportTrace() {
        guard ConversationTrace.enabled else { return }
        scrollState.trace.start()
        traceSnapshot("appear")
        scheduleTraceSnapshots()
    }

    func scheduleTraceSnapshots() {
        guard ConversationTrace.enabled, scrollState.trace.isActive else { return }
        scrollState.trace.idleTask?.cancel()
        scrollState.trace.idleTask = Task { @MainActor in
            let started = ProcessInfo.processInfo.systemUptime
            for delay in ConversationViewportTrace.idleDelays {
                do { try await Task.sleep(for: delay) } catch { return }
                guard !Task.isCancelled else { return }
                traceSnapshot("idle elapsed=\(ProcessInfo.processInfo.systemUptime - started)")
            }
        }
    }
}
