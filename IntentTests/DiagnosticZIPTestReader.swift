import Foundation
import Testing

/// Independent, strict stored-ZIP reader for regression tests. Walks the
/// central directory, follows each local-header offset, extracts payloads and
/// checks CRC using a bitwise implementation independent of the writer table.
/// Real Files/system-share interoperability is still a separate runtime gate.
nonisolated enum DiagnosticZIPTestReader {
    // Fixed byte offsets/signatures from the ZIP format, not runtime tuning.
    // swiftlint:disable no_magic_numbers
    static func extract(_ data: Data) throws -> [String: Data] {
        let end = data.count - 22
        try #require(end >= 0)
        try #require(integer(data, end, 4) == 0x06054b50)
        try #require(integer(data, end + 4, 2) == 0)
        try #require(integer(data, end + 6, 2) == 0)
        try #require(integer(data, end + 8, 2) == 2)
        try #require(integer(data, end + 10, 2) == 2)
        try #require(integer(data, end + 20, 2) == 0)
        let size = try #require(integer(data, end + 12, 4))
        var cursor = try #require(integer(data, end + 16, 4))
        try #require(cursor + size == end)
        let directoryStart = cursor
        var nextLocal = 0
        var entries: [String: Data] = [:]
        for _ in 0..<2 {
            try #require(integer(data, cursor, 4) == 0x02014b50)
            try #require(integer(data, cursor + 8, 2) == 0x0800)
            try #require(integer(data, cursor + 10, 2) == 0)
            let checksum = try #require(integer(data, cursor + 16, 4))
            let length = try #require(integer(data, cursor + 20, 4))
            try #require(integer(data, cursor + 24, 4) == length)
            let nameLength = try #require(integer(data, cursor + 28, 2))
            try #require(integer(data, cursor + 30, 2) == 0)
            try #require(integer(data, cursor + 32, 2) == 0)
            try #require(integer(data, cursor + 34, 2) == 0)
            try #require(integer(data, cursor + 38, 4) == 0)
            let local = try #require(integer(data, cursor + 42, 4))
            try #require(local == nextLocal)
            let nameData = try bytes(data, cursor + 46, nameLength)
            let name = try #require(String(data: nameData, encoding: .utf8))
            try #require(entries[name] == nil)
            try #require(integer(data, local, 4) == 0x04034b50)
            try #require(integer(data, local + 6, 2) == 0x0800)
            try #require(integer(data, local + 8, 2) == 0)
            try #require(integer(data, local + 14, 4) == checksum)
            try #require(integer(data, local + 18, 4) == length)
            try #require(integer(data, local + 22, 4) == length)
            try #require(integer(data, local + 26, 2) == nameLength)
            try #require(integer(data, local + 28, 2) == 0)
            try #require(try bytes(data, local + 30, nameLength) == nameData)
            let payload = try bytes(data, local + 30 + nameLength, length)
            try #require(Int(crc32(payload)) == checksum)
            entries[name] = payload
            nextLocal = local + 30 + nameLength + length
            cursor += 46 + nameLength
        }
        try #require(nextLocal == directoryStart)
        try #require(cursor == end)
        try #require(Set(entries.keys) == ["events.jsonl", "metadata.json"])
        return entries
    }

    private static func integer(_ data: Data, _ offset: Int, _ width: Int) -> Int? {
        guard offset >= 0, offset <= data.count, width <= data.count - offset else { return nil }
        return (0..<width).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
    }

    private static func bytes(_ data: Data, _ start: Int, _ length: Int) throws -> Data {
        try #require(start >= 0 && length >= 0 && start <= data.count && length <= data.count - start)
        return data.subdata(in: start..<(start + length))
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var value = UInt32.max
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 {
                let lowBit = value & 1
                value >>= 1
                if lowBit != 0 { value ^= 0xedb88320 }
            }
        }
        return ~value
    }
    // swiftlint:enable no_magic_numbers
}
