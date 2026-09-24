import Foundation

/// All file work and retained history live on this non-main actor. Each batch
/// commits atomically, so relaunch sees either complete old or complete new data.
actor DiagnosticWriter {
    private let storage: any DiagnosticStorage
    private let intake: DiagnosticIntake
    private let limits: DiagnosticLimits
    private let clock: @Sendable () -> Date
    private var records: [DiagnosticRecord] = []
    private var loaded = false
    private var needsPersistence = true
    private var loss = DiagnosticLoss()
    private var activeReport: DiagnosticReport?
    private var historyRevision = UUID()

    init(
        storage: any DiagnosticStorage,
        intake: DiagnosticIntake,
        limits: DiagnosticLimits,
        clock: @escaping @Sendable () -> Date
    ) {
        self.storage = storage
        self.intake = intake
        self.limits = limits
        self.clock = clock
    }

    func drain() async {
        repeat {
            flushBatch()
            if intake.finishBatch() { return }
            // Fairness for snapshot/clear without one task per record.
            await Task.yield()
        } while true
    }

    func snapshot() -> DiagnosticSnapshot {
        flushBatch()
        let counts = intake.losses()
        loss.queueOverflow = counts.overflow
        loss.invalidScope = counts.invalidScope
        let data = encodedHistory()
        let timestamp = now
        let first = records.map(\.firstTimestamp).min() ?? timestamp
        return DiagnosticSnapshot(
            jsonLines: data,
            metadata: .init(generatedAt: timestamp, retainedRecords: records.count, loss: loss),
            historyRevision: historyRevision,
            expiresAt: first.addingTimeInterval(limits.age)
        )
    }

    func clearHistory() -> Bool {
        intake.clear()
        records = []
        historyRevision = UUID()
        loss = DiagnosticLoss()
        // Never reload pre-clear history if removing a protected file failed.
        loaded = true
        var succeeded = true
        do { try storage.clearHistory() } catch { succeeded = false }
        // A different window may still have a system share consumer. Its
        // immutable report is removed by endReport, not underneath the reader.
        if activeReport == nil {
            do { try storage.clearReports() } catch { succeeded = false }
        }
        loss.storageUnavailable = !succeeded
        needsPersistence = !succeeded
        return succeeded
    }

    func beginReport() -> DiagnosticReport? {
        guard activeReport == nil else { return nil }
        return beginReport(snapshot: snapshot())
    }

    func prepareExport(reviewing snapshot: DiagnosticSnapshot) -> DiagnosticExportResult {
        guard !Task.isCancelled else { return .unavailable }
        guard snapshot.historyRevision == historyRevision,
              snapshot.metadata.generatedAt <= now, now < snapshot.expiresAt else {
            return .needsReview(self.snapshot())
        }
        guard let report = beginReport(snapshot: snapshot) else { return .unavailable }
        // File preparation may cross the retention boundary. Never hand that
        // stale archive to a new consumer; let the person review refreshed data.
        guard now < snapshot.expiresAt, snapshot.metadata.generatedAt <= now else {
            _ = endReport(report)
            return .needsReview(self.snapshot())
        }
        return .ready(report)
    }

    private func beginReport(snapshot: DiagnosticSnapshot) -> DiagnosticReport? {
        guard activeReport == nil, !Task.isCancelled else { return nil }
        do {
            let directory = try storage.prepareReport(snapshot: snapshot)
            try Task.checkCancellation()
            let report = DiagnosticReport.make(snapshot: snapshot, directory: directory)
            activeReport = report
            return report
        } catch is CancellationError {
            try? storage.clearReports()
            return nil
        } catch {
            loss.storageUnavailable = true
            try? storage.clearReports()
            return nil
        }
    }

    func endReport(_ report: DiagnosticReport) -> Bool {
        guard let activeReport, activeReport.matches(report) else { return false }
        // Even if deletion fails, the consumer has finished. The next prepare
        // or Clear retries deletion, without accumulating report directories.
        defer { self.activeReport = nil }
        do {
            try storage.clearReports()
            return true
        } catch {
            loss.storageUnavailable = true
            return false
        }
    }

    private var now: Date {
        Date(timeIntervalSince1970: clock().timeIntervalSince1970.rounded(.down))
    }

    private func flushBatch() {
        loadIfNeeded()
        let batch = intake.take()
        let timestamp = now
        let previousCount = records.count
        expire(at: timestamp)
        needsPersistence = needsPersistence || !batch.isEmpty || records.count != previousCount
        for record in batch {
            guard record.isValid else { loss.malformedRecords += 1; continue }
            if let last = records.last, last.canMerge(record),
               record.lastTimestamp.timeIntervalSince(last.firstTimestamp) < limits.age {
                records[records.count - 1].count += record.count
                records[records.count - 1].lastTimestamp = record.lastTimestamp
            } else {
                records.append(record)
            }
        }
        expire(at: timestamp)
        guard needsPersistence else { return }
        let data = boundedHistory()
        guard loaded else { return }
        do {
            try storage.replaceHistory(data)
            needsPersistence = false
        } catch {
            loss.storageUnavailable = true
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        do {
            try storage.prepare()
            if activeReport == nil {
                do { try storage.clearReports() } catch { loss.storageUnavailable = true }
            }
            let data = try storage.readHistory(maximumBytes: limits.historyBytes)
            load(data)
            loaded = true
        } catch DiagnosticFileStorage.Failure.oversizedHistory {
            loaded = true
            loss.historyReset = true
        } catch {
            // Retry on a later batch if storage becomes available. Do not turn
            // unreadable history into an empty replacement before a safe read.
            loss.storageUnavailable = true
        }
    }

    private func load(_ data: Data) {
        let decoder = DiagnosticEncoding.decoder()
        let complete = data.last == DiagnosticEncoding.newline
        let lines = data.split(separator: DiagnosticEncoding.newline, omittingEmptySubsequences: false)
        var previousRecords: [DiagnosticRecord] = []
        for (index, line) in lines.enumerated() where !line.isEmpty {
            guard complete || index < lines.count - 1, line.count <= DiagnosticLimits.maximumRecordBytes,
                  let record = try? decoder.decode(DiagnosticRecord.self, from: Data(line)), record.isValid else {
                loss.malformedRecords += 1
                continue
            }
            previousRecords.append(record)
        }
        records = previousRecords + records
    }

    private func expire(at timestamp: Date) {
        let cutoff = timestamp.addingTimeInterval(-limits.age)
        let previous = records.count
        // Age by FIRST occurrence: we cannot subtract expired occurrences from
        // a summary without retaining every timestamp. Clock rollback purges
        // future records instead of extending their retention indefinitely.
        records.removeAll { $0.firstTimestamp <= cutoff || $0.lastTimestamp > timestamp }
        loss.expiredRecords += UInt64(previous - records.count)
    }

    private func boundedHistory() -> Data {
        let encoder = DiagnosticEncoding.encoder()
        var lines: [Data] = []
        var kept: [DiagnosticRecord] = []
        var bytes = 0
        var full = false
        for record in records.reversed() {
            guard let line = try? encoder.encode(record), line.count <= DiagnosticLimits.maximumRecordBytes else {
                loss.malformedRecords += 1
                continue
            }
            guard !full, bytes + line.count + 1 <= limits.historyBytes else {
                full = true
                loss.rotatedRecords += 1
                continue
            }
            bytes += line.count + 1
            lines.append(line)
            kept.append(record)
        }
        records = kept.reversed()
        return lines.reversed().reduce(into: Data()) { data, line in
            data.append(line)
            data.append(DiagnosticEncoding.newline)
        }
    }

    private func encodedHistory() -> Data { boundedHistory() }
}
