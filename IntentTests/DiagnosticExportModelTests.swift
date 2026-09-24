import Foundation
@testable import Intent
import Testing

@MainActor
struct DiagnosticExportModelTests {
    @Test func openingOnlyPreviewsAndExplicitSharingUsesThatSnapshot() async throws {
        let storage = DiagnosticTestStorage()
        let store = DiagnosticStore(storage: storage)
        store.record(DiagnosticFixtures.event())
        let model = DiagnosticExportModel(store: store)
        model.refresh()
        await model.waitForWork()
        let preview = try #require(model.preview)
        #expect(preview.rows.count == 1)
        #expect(preview.rows.first?.record.event.operation == .workspaceLoad)
        #expect(model.share == nil)
        #expect(!FileManager.default.fileExists(atPath: storage.files.directory.appendingPathComponent("report").path))
        model.shareZIP()
        await model.waitForWork()
        let lease = try #require(model.share)
        #expect(lease.report.snapshot.jsonLines == preview.snapshot.jsonLines)
        #expect(await lease.finish())
        model.sharingFinished(id: lease.id, failed: false, cleaned: true)
        #expect(model.share == nil)
        #expect(model.notice == nil)
        #expect(!storage.state.withLock { $0.touchedMainThread })
    }

    @Test func expiredOrClearedReviewDoesNotImmediatelyOpenShareSheet() async throws {
        let store = DiagnosticStore(storage: DiagnosticTestStorage())
        store.record(DiagnosticFixtures.event())
        let model = DiagnosticExportModel(store: store)
        model.refresh()
        await model.waitForWork()
        #expect(await store.clearHistory())
        model.shareZIP()
        await model.waitForWork()
        #expect(model.share == nil)
        #expect(try #require(model.preview).rows.isEmpty)
        #expect(model.notice != nil)
    }

    @Test func clearIsExplicitAndEmptyHistoryCanStillBeShared() async throws {
        let store = DiagnosticStore(storage: DiagnosticTestStorage())
        store.record(DiagnosticFixtures.event())
        let model = DiagnosticExportModel(store: store)
        model.refresh()
        await model.waitForWork()
        #expect(!(await store.snapshot().jsonLines.isEmpty))
        model.clearHistory()
        await model.waitForWork()
        #expect(try #require(model.preview).rows.isEmpty)
        #expect(model.notice != nil)
        model.shareZIP()
        await model.waitForWork()
        let lease = try #require(model.share)
        #expect(lease.report.snapshot.jsonLines.isEmpty)
        #expect(await lease.finish())
        model.sharingFinished(id: lease.id, failed: false, cleaned: true)
    }

    @Test func preparationFailureAndCancellationLeaveNoShareAndAllowRetry() async throws {
        let storage = DiagnosticTestStorage()
        let model = DiagnosticExportModel(store: DiagnosticStore(storage: storage))
        model.refresh()
        await model.waitForWork()
        storage.state.withLock { $0.failWrite = true }
        model.shareZIP()
        await model.waitForWork()
        #expect(model.share == nil)
        #expect(model.notice != nil)
        #expect(!model.isWorking)
        storage.state.withLock { $0.failWrite = false }
        model.shareZIP()
        model.cancelPreparation()
        await model.waitForWork()
        #expect(model.share == nil)
        #expect(model.notice == nil)
        model.shareZIP()
        await model.waitForWork()
        let lease = try #require(model.share)
        #expect(await lease.finish())
        model.sharingFinished(id: lease.id, failed: true, cleaned: true)
        #expect(model.share == nil)
        #expect(model.notice != nil)
    }
}