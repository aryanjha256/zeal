# Examples

Real-world usage patterns for Zeal.

## Incident investigation

```bash
# What happened around the time of the outage?
zeal 'FROM /var/log/app.json WHERE level = "error" OR level = "fatal" SHOW LAST 50'

# Were there warnings before the errors?
zeal 'FROM /var/log/app.json WHERE level = "error" WITHIN 30s OF level = "warn"'

# Trace a single request across log entries
zeal 'FROM /var/log/app.json WHERE request_id = "abc-123"'

# Find all 5xx errors grouped by endpoint
zeal 'FROM /var/log/app.json WHERE status >= 500 GROUP BY path'
```

## Monitoring & alerting scripts

```bash
# Count errors in the last hour (pipe-friendly JSON output)
ERROR_COUNT=$(zeal --format raw 'FROM /var/log/app.json WHERE level = "error" SHOW COUNT')
if [ "$ERROR_COUNT" -gt 100 ]; then
  echo "ALERT: $ERROR_COUNT errors in the last log rotation" | mail -s "Error spike" ops@company.com
fi

# Follow production logs, pipe matches to Slack webhook
zeal --follow --format json 'FROM /var/log/app.json WHERE level = "fatal"' | \
  while read -r line; do
    curl -X POST "$SLACK_WEBHOOK" -d "{\"text\": \"FATAL: $line\"}"
  done
```

## Log format examples

### JSON logs (structured)

```bash
# Your app probably writes logs like this:
# {"timestamp":"2024-01-15T10:30:06Z","level":"error","message":"Connection timeout","request_id":"abc123"}

zeal 'FROM app.json WHERE level = "error" AND message CONTAINS "timeout"'
zeal 'FROM app.json WHERE status >= 500 GROUP BY path SHOW COUNT'
```

### logfmt (Go/Heroku-style)

```bash
# ts=2024-01-15T10:30:06Z level=error msg="Connection timeout" request_id=abc123

zeal 'FROM app.logfmt WHERE level = "error"'
```

### Plain text (syslog / Apache / anything)

```bash
# 2024-01-15 10:30:06 ERROR Connection timeout for request abc123

zeal 'FROM /var/log/syslog WHERE level = "error"'
zeal 'FROM /var/log/syslog WHERE message CONTAINS "timeout"'
```

## Multi-source analysis

```bash
# Correlate app errors with nginx 5xx responses
zeal 'FROM /var/log/app.json, /var/log/nginx/error.log WHERE status >= 500'

# Compare error rates across services
zeal 'FROM /var/log/api.json WHERE level = "error" SHOW COUNT'
zeal 'FROM /var/log/worker.json WHERE level = "error" SHOW COUNT'
```

## Temporal correlation (the killer feature)

```bash
# Database errors that happen within 2 seconds of high latency
zeal 'FROM app.json WHERE message CONTAINS "db error" WITHIN 2s OF latency_ms >= 1000'

# Auth failures followed by errors (possible attack?)
zeal 'FROM app.json WHERE level = "error" WITHIN 10s OF message CONTAINS "auth failed"'

# Deployment-related issues
zeal 'FROM app.json WHERE level = "error" WITHIN 1m OF message CONTAINS "deployed"'
```

## Piping with other tools

```bash
# Feed matches to jq for further processing
zeal --format json 'FROM app.json WHERE level = "error"' | jq '.request_id'

# Count unique request IDs with errors
zeal --format json 'FROM app.json WHERE level = "error"' | jq -r '.request_id' | sort -u | wc -l

# Pretty-print with bat
zeal --format json 'FROM app.json WHERE level = "error"' | bat -l json
```
