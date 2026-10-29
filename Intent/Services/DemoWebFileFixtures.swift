import Foundation

enum DemoWebFileFixtures {
    static let typescript = #"""
        // Typed events keep the dashboard consistent.
        export const batchLimit = 20;
        const validName = /^[a-z][a-z.]+$/i;

        export interface Activity<T> {
          readonly name: string;
          readonly payload: T;
          duration: number;
        }

        type Summary = Readonly<{ count: number; label: string }>;

        /** Collect only validated workspace activity. */
        export class Collector<T> {
          private pending: Activity<T>[] = [];

          add(event: Activity<T>): boolean {
            if (!validName.test(event.name)) return false;
            this.pending.push(event);
            return this.pending.length >= batchLimit;
          }

          summarize(): Summary {
            const count = this.pending.length;
            return { count, label: `${count} events ready` };
          }

          flush(): Activity<T>[] {
            const batch = this.pending.slice(0, batchLimit);
            this.pending = this.pending.slice(batch.length);
            return batch;
          }
        }

        export const collector = new Collector<{ workspace: string }>();
        collector.add({ name: "workspace.opened", payload: { workspace: "demo" }, duration: 42 });

        """#

    static let javascript = #"""
        // Build a small dashboard from validated activity.
        const batchLimit = 20;
        const validName = /^[a-z][a-z.]+$/i;
        const pending = new Map();

        /** @param {string} name A public event name. */
        export function track(name, duration = 0) {
          if (!validName.test(name)) return false;
          pending.set(name, { name, duration, created: Date.now() });
          return pending.size >= batchLimit;
        }

        export function summarize() {
          const events = [...pending.values()];
          const total = events.reduce((sum, event) => sum + event.duration, 0);
          const average = total / Math.max(events.length, 1);
          return {
            count: events.length,
            average,
            label: `${events.length} events in ${total}ms`,
          };
        }

        export async function flush(send) {
          const batch = [...pending.values()].slice(0, batchLimit);
          if (batch.length === 0) return;
          await send(JSON.stringify({ events: batch }));
          for (const event of batch) pending.delete(event.name);
        }

        track("workspace.opened", 42);
        console.log(summarize().label);

        """#

    static let css = #"""
        /* A responsive activity dashboard. */
        :root {
          --accent: #336699;
          --surface: #f7f9fc;
          --spacing: 1.5rem;
        }

        .dashboard {
          display: grid;
          gap: var(--spacing);
          padding: 24px;
          background: var(--surface);
        }

        .activity-card {
          color: var(--accent);
          border: 1px solid #ccddee;
          border-radius: 12px;
          padding: 1rem;
          transition: opacity 200ms;
        }

        .activity-card:hover {
          opacity: 0.9;
        }

        .activity-card::before {
          content: "Activity";
          font-weight: 600;
        }

        @media (min-width: 48rem) {
          .dashboard {
            grid-template-columns: repeat(3, 1fr);
          }
        }

        """#

    static let shell = #"""
        #!/usr/bin/env bash
        # Summarize local demo activity without sending data.
        set -euo pipefail

        report_dir="${TMPDIR:-/tmp}/intent-demo-report"
        batch_limit=20
        format='event=%s duration=%s\n'

        describe_batch() {
          local count="$1"
          if test "$count" -gt "$batch_limit"; then
            printf 'Batch exceeds limit: %s\n' "$count"
            return 1
          fi
          printf 'Preparing %s events\n' "$count"
        }

        mkdir -p "$report_dir"
        generated_at="$(date -u +%Y-%m-%d)"
        describe_batch 2

        for event in workspace.opened task.completed; do
          printf "$format" "$event" 42
        done

        cat <<REPORT
        Activity report
        Generated: $generated_at
        Output: $report_dir
        REPORT

        printf 'Report complete: %s\n' "$report_dir"

        """#
}
