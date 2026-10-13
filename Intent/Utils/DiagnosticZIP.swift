import Foundation

/// Deliberately not a general archive library: two fixed UTF-8 names, stored
/// (uncompressed) entries, no paths supplied by callers, extras, or timestamps.
/// Classic ZIP APPNOTE local headers + central directory + end record. Sizes
/// are bounded well below ZIP64 and all integers are written little-endian.
nonisolated enum DiagnosticZIP {
    enum Failure: Error { case oversized }

    static let maximumMetadataBytes = 16_384
    private static let maximumHeaderBytes = 1024
    static let maximumArchiveBytes = DiagnosticLimits.maximumHistoryBytes + maximumMetadataBytes + maximumHeaderBytes

    // Classic ZIP APPNOTE signatures and fixed fields for stored UTF-8 entries.
    private static let localHeaderSignature: UInt32 = 0x04034b50
    private static let centralDirectorySignature: UInt32 = 0x02014b50
    private static let endOfDirectorySignature: UInt32 = 0x06054b50
    private static let version20: UInt16 = 20
    private static let utf8Flag: UInt16 = 0x0800
    private static let dosEpochDate: UInt16 = 0x0021 // 1980-01-01; no filesystem metadata
    private static let reversedCRC32Polynomial: UInt32 = 0xedb88320
    private static let checksumCancellationInterval = 16_384

    private struct Entry {
        let name: Data
        let bytes: Data
        let checksum: UInt32
        let offset: UInt32
    }

    static func encode(_ snapshot: DiagnosticSnapshot) throws -> Data {
        guard snapshot.jsonLines.count <= DiagnosticLimits.maximumHistoryBytes else { throw Failure.oversized }
        let metadata = try snapshot.metadataJSON()
        guard metadata.count <= maximumMetadataBytes else { throw Failure.oversized }
        let payloads = [("events.jsonl", snapshot.jsonLines), ("metadata.json", metadata)]
        var archive = Data()
        var entries: [Entry] = []
        for (name, bytes) in payloads {
            try Task.checkCancellation()
            let entry = Entry(name: Data(name.utf8), bytes: bytes, checksum: try crc32(bytes), offset: UInt32(archive.count))
            appendLocal(entry, to: &archive)
            entries.append(entry)
        }
        let directoryOffset = UInt32(archive.count)
        for entry in entries { appendCentral(entry, to: &archive) }
        let directorySize = UInt32(archive.count) - directoryOffset
        appendEnd(count: UInt16(entries.count), size: directorySize, offset: directoryOffset, to: &archive)
        guard archive.count <= maximumArchiveBytes else { throw Failure.oversized }
        return archive
    }

    private static func appendLocal(_ entry: Entry, to data: inout Data) {
        append(localHeaderSignature, to: &data)
        append(version20, to: &data)
        append(utf8Flag, to: &data)
        append(UInt16(0), to: &data) // Stored
        append(UInt16(0), to: &data) // DOS time
        append(dosEpochDate, to: &data)
        append(entry.checksum, to: &data)
        append(UInt32(entry.bytes.count), to: &data)
        append(UInt32(entry.bytes.count), to: &data)
        append(UInt16(entry.name.count), to: &data)
        append(UInt16(0), to: &data) // No extras
        data.append(entry.name)
        data.append(entry.bytes)
    }

    private static func appendCentral(_ entry: Entry, to data: inout Data) {
        append(centralDirectorySignature, to: &data)
        append(version20, to: &data) // Made by DOS, version 2.0
        append(version20, to: &data)
        append(utf8Flag, to: &data)
        append(UInt16(0), to: &data)
        append(UInt16(0), to: &data)
        append(dosEpochDate, to: &data)
        append(entry.checksum, to: &data)
        append(UInt32(entry.bytes.count), to: &data)
        append(UInt32(entry.bytes.count), to: &data)
        append(UInt16(entry.name.count), to: &data)
        append(UInt16(0), to: &data) // Extra length
        append(UInt16(0), to: &data) // Comment length
        append(UInt16(0), to: &data) // Disk
        append(UInt16(0), to: &data) // Internal attributes
        append(UInt32(0), to: &data) // External attributes (not a symlink)
        append(entry.offset, to: &data)
        data.append(entry.name)
    }

    private static func appendEnd(count: UInt16, size: UInt32, offset: UInt32, to data: inout Data) {
        append(endOfDirectorySignature, to: &data)
        append(UInt16(0), to: &data)
        append(UInt16(0), to: &data)
        append(count, to: &data)
        append(count, to: &data)
        append(size, to: &data)
        append(offset, to: &data)
        append(UInt16(0), to: &data)
    }

    private static let crcTable: [UInt32] = (0...Int(UInt8.max)).map { value in
        var remainder = UInt32(value)
        for _ in 0..<UInt8.bitWidth {
            remainder = (remainder >> 1) ^ (remainder & 1 == 0 ? 0 : reversedCRC32Polynomial)
        }
        return remainder
    }

    private static func crc32(_ data: Data) throws -> UInt32 {
        var checksum = UInt32.max
        for (index, byte) in data.enumerated() {
            if index.isMultiple(of: checksumCancellationInterval) { try Task.checkCancellation() }
            checksum = (checksum >> UInt8.bitWidth) ^ crcTable[Int((checksum ^ UInt32(byte)) & UInt32(UInt8.max))]
        }
        return checksum ^ UInt32.max
    }

    private static func append<Value: FixedWidthInteger>(_ value: Value, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
