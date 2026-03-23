<p align="center">
  <b>⚡ zeal</b><br>
  <i>A structured log query language — like jq, but for logs.</i>
</p>

<p align="center">
  <a href="#install">Install</a> •
  <a href="#quick-start">Quick Start</a> •
  <a href="#temporal-correlation">Temporal Correlation</a> •
  <a href="#query-language">Query Language</a> •
  <a href="examples/">Examples</a>
</p>

<p align="center">
  <a href="https://github.com/aryanjha256/zeal/actions/workflows/ci.yml"><img src="https://github.com/aryanjha256/zeal/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
  <a href="https://github.com/aryanjha256/zeal/releases"><img src="https://img.shields.io/github/v/release/aryanjha256/zeal?include_prereleases" alt="Release"></a>
</p>

---

```bash
# Find errors. Instantly.
zeal 'FROM /var/log/app.json WHERE level = "error"'

# The killer feature: find errors that happened within 5s of a warning
zeal 'FROM /var/log/app.json WHERE level = "error" WITHIN 5s OF level = "warn"'
```

**Zeal** is a single static binary that lets you query log files with a SQL-like language. Auto-detects JSON, logfmt, and plain text. Zero dependencies. Built in Zig for speed.

### Why?

- **`grep`** can't filter by field values, do numeric comparisons, or correlate events
- **`jq`** is great for JSON but can't handle logfmt/plain text and has no temporal logic
- **`zeal`** gives you a single, consistent query language across _all_ log formats — plus temporal correlation that neither can do

## Install

### Pre-built binaries

Download from [Releases](https://github.com/aryanjha256/zeal/releases):

```bash
# Linux (x86_64)
curl -Lo zeal.tar.gz https://github.com/aryanjha256/zeal/releases/latest/download/zeal-x86_64-linux.tar.gz
tar xzf zeal.tar.gz
sudo mv zeal-x86_64-linux /usr/local/bin/zeal

# macOS (Apple Silicon)
curl -Lo zeal.tar.gz https://github.com/aryanjha256/zeal/releases/latest/download/zeal-aarch64-macos.tar.gz
tar xzf zeal.tar.gz
sudo mv zeal-aarch64-macos /usr/local/bin/zeal
```

### From source

Requires [Zig 0.16+](https://ziglang.org/download/):

```bash
git clone https://github.com/aryanjha256/zeal.git
cd zeal
zig build -Doptimize=ReleaseFast
sudo cp zig-out/bin/zeal /usr/local/bin/
```

### Shell completions

```bash
# Bash
sudo cp completions/zeal.bash /etc/bash_completion.d/zeal

# Zsh
sudo cp completions/zeal.zsh /usr/local/share/zsh/site-functions/_zeal

# Fish
cp completions/zeal.fish ~/.config/fish/completions/
```

## Quick Start

```bash
# Filter by level
zeal 'FROM app.json WHERE level = "error"'

# Numeric comparison
zeal 'FROM app.json WHERE status >= 500 SHOW LAST 10'

# Substring search (case-insensitive)
zeal 'FROM app.json WHERE message CONTAINS "timeout"'

# Count matches
zeal 'FROM app.json WHERE level = "error" SHOW COUNT'

# Group errors by field
zeal 'FROM app.json WHERE level = "error" GROUP BY request_id'

# Output as JSON (pipe to jq, etc.)
zeal --format json 'FROM app.json WHERE level = "error"' | jq '.request_id'

# Follow a file in real time (like tail -f, but filtered)
zeal --follow 'FROM /var/log/app.log WHERE level = "error"'
```

## Temporal Correlation

The killer feature. Find events that occur _near_ other events in time:

```bash
# Errors within 5 seconds of a warning
zeal 'FROM app.json WHERE level = "error" WITHIN 5s OF level = "warn"'

# Timeouts after a deployment
zeal 'FROM app.json WHERE message CONTAINS "timeout" WITHIN 1m OF message CONTAINS "deployed"'

# DB errors near high latency
zeal 'FROM app.json WHERE message CONTAINS "db error" WITHIN 2s OF latency_ms >= 1000'
```

Duration units: `ms`, `s`, `m`, `h`, `d`

Uses binary search on sorted timestamps — **O(n log m)** performance.

## Query Language

```
FROM <source>, ...
[WHERE <expression>]
[GROUP BY <field>, ...]
[SHOW FIRST|LAST <n> | SHOW COUNT]
```

### Operators

| Operator          | Example                             | Description                                |
| ----------------- | ----------------------------------- | ------------------------------------------ |
| `=`               | `level = "error"`                   | Exact match (case-insensitive for strings) |
| `!=`              | `level != "debug"`                  | Not equal                                  |
| `>` `<` `>=` `<=` | `status >= 500`                     | Numeric/string comparison                  |
| `CONTAINS`        | `message CONTAINS "timeout"`        | Case-insensitive substring search          |
| `AND` `OR` `NOT`  | `level = "error" AND status >= 500` | Boolean logic                              |
| `WITHIN...OF`     | `... WITHIN 5s OF ...`              | Temporal correlation                       |

### Nested fields

```bash
# Access nested JSON fields with dot notation
zeal 'FROM app.json WHERE request.headers.host = "api.example.com"'
```

### Multiple sources

```bash
zeal 'FROM /var/log/app.log, /var/log/nginx.log WHERE status >= 500'

# Or use -f flags
zeal -f app.log -f nginx.log 'WHERE status >= 500'
```

## Log Formats

Zeal auto-detects the format from the first line:

| Format         | Detection         | Example                                 |
| -------------- | ----------------- | --------------------------------------- |
| **JSON**       | Starts with `{`   | `{"level":"error","message":"timeout"}` |
| **logfmt**     | `key=value` pairs | `level=error msg="timeout" req=abc`     |
| **Plain text** | Everything else   | `2024-01-15 10:30:06 ERROR timeout`     |

**Auto-mapped fields:** `level`/`lvl`/`severity`, `message`/`msg`, `timestamp`/`ts`/`time`/`@timestamp`

## CLI Reference

```
Usage:
  zeal '<query>'
  zeal -f <file> [options] '<query>'

Options:
  -h, --help            Show help
  -V, --version         Show version
  -f, --file <path>     Log file (can repeat; alternative to FROM)
  --format <fmt>        Output: text (default), json, raw
  --no-color            Disable color output
  --color <mode>        auto | always | never
  -F, --follow          Tail file for new entries (like tail -f)
  --explain             Show query plan without executing
```

### Output formats

```bash
# Human-readable with colors (default)
zeal 'FROM app.json WHERE level = "error"'

# NDJSON — one JSON object per line, pipe-friendly
zeal --format json 'FROM app.json WHERE level = "error"'

# Raw — original log lines, zero decoration
zeal --format raw 'FROM app.json WHERE level = "error"'
```

### Explain mode

See what zeal will do without running the query:

```
$ zeal --explain 'FROM app.json WHERE level = "error" WITHIN 5s OF level = "warn" GROUP BY request_id'

Query Plan

  1. READ app.json (auto-detect format)
  2. SCAN all entries
  3. FILTER condition: level eq "error"
  4. TEMPORAL find entries WITHIN 5s OF level eq "warn"
     Strategy: binary search on sorted timestamps
  5. GROUP BY request_id
     Strategy: hash aggregation
  6. OUTPUT text format
```

## Performance

Benchmarked on 10,000 JSON log entries (`bench/bench.sh 10000`):

| Query                                          | zeal    | jq   | grep |
| ---------------------------------------------- | ------- | ---- | ---- |
| Simple filter (`level = "error"`)              | **5ms** | 16ms | 2ms  |
| Numeric (`status >= 500`)                      | **6ms** | 16ms | —    |
| Compound (`level = "error" AND status >= 500`) | **5ms** | 15ms | —    |
| `CONTAINS "timeout"`                           | **5ms** | 32ms | 2ms  |
| Count                                          | **6ms** | 16ms | 2ms  |

Zeal is **2–6x faster than jq** for structured queries while supporting all log formats, not just JSON.

```bash
# Run benchmarks yourself
zig build -Doptimize=ReleaseFast
./bench/bench.sh 10000
```

## Error Messages

Zeal shows exactly where it got confused:

```
error: expected a value (string, number, true, false, null)
  │ FROM app.json WHERE level =
  │                             ^
  │ found: end of query
```

## Development

```bash
zig build              # debug build
zig build test         # run 70+ tests
zig build run -- 'FROM testdata/app.json WHERE level = "error"'
zig build -Doptimize=ReleaseFast   # optimized build (~5MB static binary)
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

[MIT](LICENSE) — Aryan Kumar
