enum DemoConfigurationFileFixtures {
    static let json = #"""
    {
      "schemaVersion": 2,
      "name": "workspace-analytics",
      "enabled": true,
      "collection": {
        "batchSize": 20,
        "flushIntervalSeconds": 30,
        "sampleRate": 0.75,
        "events": [
          "workspace.opened",
          "task.completed",
          "agent.finished"
        ]
      },
      "privacy": {
        "includePaths": false,
        "includePrompts": false,
        "retentionDays": 7
      },
      "delivery": {
        "endpoint": "https://analytics.example.com/events",
        "region": "eu-west",
        "retryLimit": 5,
        "backoffSeconds": [1, 2, 4, 8],
        "headers": {
          "Content-Type": "application/json"
        }
      },
      "fallback": null
    }

    """#

    static let yaml = #"""
    # Analytics delivery settings for the demo workspace.
    version: 2
    service: workspace-analytics
    enabled: true

    defaults: &delivery
      batch_size: 20
      flush_interval: 30
      region: eu-west

    environments:
      development:
        <<: *delivery
        endpoint: "https://dev.example.com/events"
        sample_rate: 1.0
      production:
        <<: *delivery
        endpoint: "https://analytics.example.com/events"
        sample_rate: 0.75

    # Never send paths or prompts to the metrics service.
    privacy:
      include_paths: false
      include_prompts: false
      retention_days: 7

    retry:
      limit: 5
      backoff: [1, 2, 4, 8]
    description: |
      Queue events locally while offline.
      Flush after the user opts in.

    """#

    static let toml = #"""
    # Workspace analytics configuration.
    schema_version = 2
    enabled = true
    name = "workspace-analytics"

    [collection]
    batch_size = 20
    flush_interval = 30
    sample_rate = 0.75
    events = ["workspace.opened", "task.completed"]

    [privacy]
    include_paths = false
    include_prompts = false
    retention_days = 7

    # Retry transient failures without growing the queue.
    [delivery]
    endpoint = "https://analytics.example.com/events"
    region = "eu-west"
    retry_limit = 5
    backoff_seconds = [1, 2, 4, 8]

    [delivery.headers]
    content_type = "application/json"

    [[dashboards]]
    name = "Daily activity"
    refresh_seconds = 60
    visible = true

    """#

    static let nginx = #"""
    # Local dashboard gateway; TLS terminates upstream.
    worker_processes auto;

    events {
        worker_connections 1024;
    }

    http {
        default_type application/json;
        sendfile on;
        keepalive_timeout 65;

        upstream analytics {
            server 127.0.0.1:8080;
            keepalive 16;
        }

        server {
            listen 127.0.0.1:8081;
            server_name dashboard.local;

            location /events {
                proxy_pass http://analytics;
                proxy_set_header Host $host;
                proxy_read_timeout 30s;
            }

            location /health {
                return 200 '{"status":"ready"}';
            }
        }
    }

    """#
}
