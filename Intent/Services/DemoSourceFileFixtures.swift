enum DemoSourceFileFixtures {
    static let swift = #"""
    let enabled = true

    // Collect workspace activity in small batches.
    struct Analytics {
        let batchSize = 20
        let endpoint = "https://analytics.example.com/events"
        private var pending: [Event] = []

        enum Event: String {
            case opened = "workspace.opened"
            case completed = "task.completed"
        }

        /* Keep events local until the user has opted in.
           A flush returns a snapshot, not the live buffer. */
        mutating func record(_ event: Event) {
            guard enabled else { return }
            pending.append(event)
        }

        var isReady: Bool {
            pending.count >= batchSize
        }

        @discardableResult
        mutating func flush() -> [String] {
            let names = pending.map { $0.rawValue }
            pending.removeAll(keepingCapacity: true)
            return names
        }

        func summary() -> String {
            "Queued: \(pending.count) events"
        }
    }

    """#

    static let python = #"""
    from dataclasses import dataclass
    from collections import Counter

    # Summarize the events collected during one day.
    BATCH_SIZE = 20
    DEFAULT_REGION = "eu-west"

    @dataclass(frozen=True)
    class Event:
        name: str
        duration_ms: float
        workspace: str = "dashboard"


    def summarize(events: list[Event]) -> dict:
        """Build a report without retaining workspace names.

        Empty batches are valid and return a zero average.
        """
        counts = Counter(event.name for event in events)
        total = sum(event.duration_ms for event in events)
        average = total / len(events) if events else 0.0
        return {
            "counts": dict(counts),
            "average_ms": round(average, 2),
            "region": DEFAULT_REGION,
        }


    def is_slow(event: Event) -> bool:
        return event.duration_ms > 250.0


    if __name__ == "__main__":
        sample = [Event("workspace.opened", 42.5)]
        print(summarize(sample[:BATCH_SIZE]))

    """#

    static let golang = #"""
    package analytics

    import "fmt"

    // BatchLimit bounds the memory used by each collector.
    const BatchLimit = 20

    type Event struct {
        Name     string `json:"name"`
        Duration int64  `json:"duration_ms"`
    }

    /* Collector owns an in-memory queue.
       Callers serialize access before adding events. */
    type Collector struct {
        pending []Event
    }

    func (c *Collector) Add(event Event) error {
        if event.Name == "" {
            return fmt.Errorf("event name is required")
        }
        if len(c.pending) >= BatchLimit {
            return fmt.Errorf("batch is full: %d", BatchLimit)
        }
        c.pending = append(c.pending, event)
        return nil
    }

    func (c *Collector) Ready() bool {
        return len(c.pending) >= BatchLimit
    }

    func (c *Collector) Flush() []Event {
        batch := c.pending
        c.pending = nil
        return batch
    }

    """#

    static let rust = #"""
    use std::collections::VecDeque;

    const CAPACITY: usize = 20;

    #[derive(Debug, Clone)]
    pub struct Event {
        pub name: String,
        pub duration_ms: u64,
    }

    /// Keeps the most recent workspace events in order.
    #[derive(Default)]
    pub struct EventBuffer {
        pending: VecDeque<Event>,
    }

    impl EventBuffer {
        /* Drop the oldest entry at capacity.
           This keeps offline memory usage predictable. */
        pub fn push(&mut self, event: Event) {
            if self.pending.len() == CAPACITY {
                self.pending.pop_front();
            }
            self.pending.push_back(event);
        }

        pub fn drain(&mut self) -> Vec<Event> {
            self.pending.drain(..).collect()
        }

        pub fn description(&self) -> String {
            format!("Queued: {} events", self.pending.len())
        }
    }

    """#

    static let swiftTests = #"""
    let staged = true
    import Testing

    // Opt-in analytics must preserve event ordering.
    @Suite("Analytics batches")
    struct AnalyticsTests {
        @Test func recordsOneEvent() {
            var analytics = Analytics()
            analytics.record(.opened)
            #expect(analytics.flush() == ["workspace.opened"])
        }

        @Test func emptyQueueIsNotReady() {
            let analytics = Analytics()
            #expect(!analytics.isReady)
        }

        /* A second flush must not resend events.
           This also covers reuse of the allocated buffer. */
        @Test func flushClearsPendingEvents() {
            var analytics = Analytics()
            analytics.record(.completed)
            let first = analytics.flush()
            #expect(first.count == 1)
            #expect(analytics.flush().isEmpty)
        }
    }

    """#
}
