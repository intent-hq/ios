/// Fixed-capacity, least-recently-touched-first retention. Keeps recently
/// viewed content readable during a connection drop (read-only mode).
struct RecentRetention<Key: Hashable, Value> {
    let capacity: Int
    private(set) var keys: [Key] = []
    private var values: [Key: Value] = [:]

    init(capacity: Int) {
        self.capacity = capacity
    }

    func value(for key: Key) -> Value? { values[key] }

    /// Marks `key` most recent and drops the oldest entries beyond capacity.
    mutating func touch(_ key: Key, value: Value) {
        keys.removeAll { $0 == key }
        keys.append(key)
        values[key] = value
        while keys.count > capacity {
            values[keys.removeFirst()] = nil
        }
    }

    mutating func removeAll() {
        keys.removeAll()
        values.removeAll()
    }
}
