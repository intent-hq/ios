enum DemoMarkupFileFixtures {
    static let markdown = #"""
    # Usage analytics

    A privacy-first dashboard for workspace activity.

    ## Collection

    Events stay **local** until analytics is enabled.
    Each batch contains at most `20` entries.

    - Track workspace opens and completed tasks.
    - Keep event ordering stable during retries.
    - Never include prompts or absolute file paths.

    ## Quick start

    ```swift
    var analytics = Analytics()
    analytics.record(.opened)
    let batch = analytics.flush()
    ```

    > Offline sessions keep their queue until reconnecting.

    | Setting | Default | Purpose |
    | --- | --- | --- |
    | Batch size | 20 | Bound memory |
    | Retention | 7 days | Limit stored history |
    | Sample rate | 0.75 | Reduce traffic |

    <!-- Keep this checklist in sync with the release review. -->
    ## Release checklist

    1. Review the [configuration](Config/analytics.yaml).
    2. Run unit tests in light and dark appearances.
    3. Confirm that empty batches are not sent.

    """#

    static let xml = #"""
    <?xml version="1.0" encoding="UTF-8"?>
    <!-- Dashboard layout for the workspace report. -->
    <dashboard version="2" theme="system">
      <title>Workspace activity</title>
      <description>
        Recent events &amp; completed tasks
      </description>

      <!-- Cards share the same refresh interval.
           Values are loaded from the local event store. -->
      <cards refresh-seconds="30">
        <card id="opened" enabled="true">
          <label>Workspaces opened</label>
          <metric name="workspace.opened" />
          <threshold warning="50" critical="100" />
        </card>
        <card id="completed" enabled="true">
          <label>Tasks completed</label>
          <metric name="task.completed" />
          <threshold warning="20" critical="40" />
        </card>
      </cards>

      <empty-state>
        <message>No events yet</message>
        <hint><![CDATA[Open a workspace to begin.]]></hint>
      </empty-state>
      <privacy include-paths="false" retention-days="7" />
    </dashboard>

    """#

    static let html = #"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width">
      <title>Workspace activity</title>
    </head>
    <body>
      <!-- A semantic, keyboard-friendly report. -->
      <header>
        <h1>Usage analytics</h1>
        <p>Local events from the last 7 days.</p>
      </header>
      <main id="report">
        <section aria-labelledby="summary">
          <h2 id="summary">Daily summary</h2>
          <dl>
            <dt>Workspaces opened</dt>
            <dd data-count="42">42</dd>
            <dt>Tasks completed</dt>
            <dd data-count="18">18</dd>
          </dl>
        </section>
        <!-- No scripts or remote resources are required.
             The report can be shared while offline. -->
        <details>
          <summary>Privacy settings</summary>
          <p>Prompts &amp; file paths are never collected.</p>
        </details>
      </main>
      <footer><small>Updated at 09:41</small></footer>
    </body>
    </html>

    """#

    static let patch = #"""
    diff --git a/Config/analytics.yaml b/Config/analytics.yaml
    index 84d7a12..6bc2981 100644
    --- a/Config/analytics.yaml
    +++ b/Config/analytics.yaml
    @@ -1,7 +1,7 @@
     # Analytics delivery settings for the demo workspace.
    -version: 1
    +version: 2
     service: workspace-analytics
    -enabled: false
    +enabled: true

     defaults: &delivery
       batch_size: 20
    @@ -25,8 +25,8 @@
       retention_days: 7

     retry:
    -  limit: 3
    +  limit: 5
       backoff: [1, 2, 4, 8]
     description: |
       Queue events locally while offline.
    -  Flush immediately on launch.
    +  Flush after the user opts in.

    """#
}
