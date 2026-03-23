# Changelog

All notable changes to Zeal will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-03-23

### Added

- **Query Language** — SQL-inspired syntax: `FROM`, `WHERE`, `GROUP BY`, `SHOW`
- **Temporal Correlation** — `WITHIN 5s OF` finds events near other events using binary search
- **Auto-detection** — JSON, logfmt, and plain text log formats detected from first line
- **Zero-copy parsing** — fields are slices into the original file buffer, no allocations
- **Output formats** — human-readable text (with ANSI color), NDJSON, and raw modes
- **Follow mode** (`--follow` / `-F`) — tail a file with live filtering, handles log rotation
- **Explain mode** (`--explain`) — prints the query execution plan without running it
- **GROUP BY** — aggregate entries by field values with hash-based grouping
- **SHOW** — `SHOW FIRST n`, `SHOW LAST n`, `SHOW COUNT` for output limiting
- **Operators** — `=`, `!=`, `>`, `<`, `>=`, `<=`, `CONTAINS`, `MATCHES`
- **Boolean logic** — `AND`, `OR`, `NOT`, parenthesized expressions
- **Nested fields** — `request.headers.host` for JSON with nested objects
- **Multiple sources** — `FROM a.log, b.log` or repeated `-f` flags
- **Error messages** — caret-highlighted diagnostics with human-friendly descriptions
- **Shell completions** — bash, zsh, fish
- **Man page** — `doc/zeal.1`
- **CI** — GitHub Actions: build, test, lint, cross-compile (Linux + macOS, x86_64 + aarch64)
- **Benchmarks** — `bench/bench.sh` comparing zeal vs `grep | jq`

[0.1.0]: https://github.com/aryanjha256/zeal/releases/tag/v0.1.0
