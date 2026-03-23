# Zeal — Progress Tracker

> A structured log query language + runtime — like `jq` but for logs.
> Single static Zig binary. Zero-copy parsing. Temporal correlation.

---

## Architecture

```
src/
  main.zig          CLI entry point — arg parsing, orchestration, output
  root.zig          Library root — re-exports public API for the `zeal` module
  ast.zig           AST node types for the query language
  lexer.zig         Streaming tokenizer (zero-copy, slices into source)
  parser.zig        Recursive-descent parser → AST
  log_reader.zig    File reader + zero-copy line iteration   [Phase 2]
  log_parser.zig    Auto-detect & parse log formats (JSON/logfmt/syslog/plain)  [Phase 2]
  evaluator.zig     Query evaluation engine — filter, match, project   [Phase 3]
  temporal.zig      Temporal correlation engine (WITHIN X OF)   [Phase 3]
  cli.zig           CLI argument parser — flags, options, validation  [Phase 4]
  formatter.zig     Output formatting — text, JSON (NDJSON), raw, ANSI color  [Phase 4]
completions/
  zeal.bash         Bash completion
  zeal.zsh          Zsh completion
  zeal.fish         Fish completion
doc/
  zeal.1            Man page (troff)
bench/
  bench.sh          Benchmark suite vs grep+jq
.github/workflows/
  ci.yml            CI pipeline (build, test, lint, cross-compile)
```

## Query Language Grammar

```
query       := from_clause where_clause? group_by_clause? show_clause?

from_clause := FROM source (',' source)*
source      := STRING | /path/to/file | STDIN

where_clause := WHERE expr
expr         := or_expr
or_expr      := and_expr (OR and_expr)*
and_expr     := unary (AND unary)*
unary        := comparison (WITHIN duration OF comparison)?
              | NOT unary
              | '(' expr ')'

comparison   := field_ref op value
field_ref    := identifier ('.' identifier)*
op           := = | != | > | < | >= | <= | CONTAINS | MATCHES
value        := STRING | NUMBER | true | false | null

duration     := NUMBER time_unit
time_unit    := ms | s | m | h | d

group_by_clause := GROUP BY field_ref (',' field_ref)*
show_clause     := SHOW (FIRST | LAST) NUMBER
                 | SHOW COUNT
                 | SHOW field_ref (',' field_ref)*
```

## Example Queries

```sql
-- Simple filter
FROM /var/log/app.log WHERE level = "error" SHOW LAST 20

-- Temporal correlation (the killer feature)
FROM /var/log/app.log WHERE level = "error" WITHIN 5s OF level = "warn" GROUP BY request_id

-- Multiple sources
FROM /var/log/app.log, /var/log/nginx/access.log WHERE status >= 500

-- Stdin piping
FROM stdin WHERE message CONTAINS "timeout" SHOW COUNT

-- Nested field access
FROM /var/log/app.json WHERE request.headers.host = "api.example.com"
```

---

## Phases

### Phase 1: Query Language Core ✅

- [x] AST types (`src/ast.zig`)
- [x] Lexer / tokenizer (`src/lexer.zig`)
- [x] Recursive-descent parser (`src/parser.zig`)
- [x] Root module re-exports (`src/root.zig`)
- [x] CLI skeleton — parse query, print AST summary (`src/main.zig`)
- [x] Build verification + smoke test

### Phase 2: Log Input ✅

- [x] Log entry types — `LogEntry`, `LogLevel`, `Field` (`src/log_entry.zig`)
- [x] File reader — Zig 0.16 `Io.Dir` + `File.Reader` API (`src/log_reader.zig`)
- [x] Zero-copy `LineIterator` — splits buffer into lines without allocation
- [x] Log format auto-detection — JSON, logfmt, syslog, plain text (`src/log_parser.zig`)
- [x] JSON parser — zero-copy key-value extraction with nested object skipping
- [x] Logfmt parser — `key=value` and `key="quoted value"` patterns
- [x] Plain text parser — `[LEVEL]`, `LEVEL`, and timestamp detection
- [x] Relative path support in parser (e.g., `testdata/app.json`)
- [x] ANSI-colored level output in structured log display
- [x] SHOW LAST/FIRST/COUNT execution against parsed entries
- [x] Multi-source display with per-source format detection
- [x] Graceful error handling for missing/unreadable files
- [ ] Stdin streaming support (deferred)
- [ ] Glob/wildcard source paths (deferred)

### Phase 3: Query Engine ✅

- [x] Filter evaluator — `matches(entry, expr)` with AND/OR/NOT logic (`src/evaluator.zig`)
- [x] Field resolution — dotted field refs, well-known fields (level/message/timestamp), nested JSON lookup
- [x] Comparison operators — `=`, `!=`, `>`, `<`, `>=`, `<=` with case-insensitive string + numeric coercion
- [x] `CONTAINS` operator — case-insensitive substring search
- [x] Temporal correlation engine — binary search over sorted anchor timestamps (`src/temporal.zig`)
- [x] ISO 8601 timestamp parsing to nanoseconds (i128) with `daysSinceEpoch` algorithm
- [x] GROUP BY aggregation — `StringHashMap` of group_key → entry indices, single-field fast path
- [x] GROUP BY display — box-drawing characters, per-group SHOW FIRST/LAST limits
- [x] SHOW FIRST/LAST/COUNT execution integrated into full pipeline
- [x] End-to-end pipeline in main.zig: parse → read → detect → filter/correlate → group → show → display

### Phase 4: Output & CLI ✅

- [x] Output formatter module with text/JSON/raw modes (`src/formatter.zig`)
- [x] JSON output — valid NDJSON, one object per entry, `_group` key for grouped output
- [x] Raw output — original log lines, no decoration
- [x] Text output — ANSI-colored structured display (default)
- [x] TTY auto-detection — `Io.File.isTty()` for color mode
- [x] `--no-color` / `--color auto|always|never` flags
- [x] Full CLI argument parser (`src/cli.zig`) — `-f`, `--format`, `--follow`, `--explain`
- [x] `-f`/`--file` flag — alternative/supplement to FROM clause, dedup with FROM sources
- [x] `--format text|json|raw` — output format selection
- [x] `--follow` / `-F` — tail mode with 200ms polling, handles log rotation (truncation detect)
- [x] `--explain` mode — query plan with steps, strategies, and output format
- [x] `--help` / `-h` with full usage, examples, and syntax reference
- [x] `--version` / `-V` flag
- [x] Error messages for invalid flags, missing values, unknown formats
- [x] Synthetic FROM clause from `-f` flags when query has no FROM
- [x] Colored query summary with field highlighting

### Phase 5: Polish & Release ✅

- [x] Enhanced error messages with caret highlighting and human-friendly descriptions
- [x] Error context: shows found token, expected alternatives, and exact position
- [x] README.md — install instructions, query language docs, examples, architecture
- [x] Shell completions — bash (`completions/zeal.bash`), zsh (`completions/zeal.zsh`), fish (`completions/zeal.fish`)
- [x] Man page — `doc/zeal.1` with full troff formatting, renders with `man -l`
- [x] CI pipeline — GitHub Actions (`ci.yml`): build + test (Linux/macOS), formatting check, cross-compile (x86_64/aarch64 Linux/macOS)
- [x] Benchmark script — `bench/bench.sh` compares zeal vs `grep | jq` pipelines on generated 10K-line JSON logs

### Phase 6: Code Quality & Bug Fixes ✅

- [x] **bench.sh**: Fixed `LINES` → `NUM_LINES` (bash built-in conflict caused 28-entry runs instead of N)
- [x] **bench.sh**: Fixed JSON separator mismatch (compact `json.dumps(separators=(',',':'))` matches grep patterns)
- [x] **bench.sh**: Fixed `set -e` causing exit on grep zero-match (changed to `set -uo pipefail` + `|| true`)
- [x] **log_reader.zig**: Fixed `readSliceShort` partial reads — now loops until all bytes consumed
- [x] **log_reader.zig**: Replaced recursive `next()` with iterative `while` loop (prevents stack overflow on many empty lines)
- [x] **parser.zig**: Added EOF check after `parse()` — rejects trailing garbage tokens (e.g., `WHERE level = "error" JUNK`)
- [x] **parser.zig**: Improved `stripQuotes` with escape detection
- [x] **temporal.zig**: Added timezone offset parsing (`+05:30`, `-08:00`, `+0530`, `Z`) — offsets were silently ignored
- [x] **temporal.zig**: Propagate OOM from `buildGroupKey` instead of silently grouping under `"(error)"`
- [x] **temporal.zig**: Removed unused `allocator` field from `GroupResult`
- [x] **evaluator.zig**: Float equality uses epsilon comparison (`@abs(parsed - f) < 1e-9`)
- [x] **evaluator.zig**: String ordering now case-insensitive (consistent with `evalEq`)
- [x] **evaluator.zig**: Removed dead `extractGroupKey` function
- [x] **main.zig**: Non-zero exit codes on parse errors and invalid CLI args (`std.process.exit(1)`)
- [x] **main.zig**: Proper stderr message for unsupported stdin
- [x] **main.zig**: Follow mode only allocates for new bytes (not entire file each poll)
- [x] **cli.zig + formatter.zig**: Unified `OutputFormat` enum — cli.zig now imports from formatter.zig
- [x] **Tests**: Added 70 total tests (up from ~40) — timezone offsets, float epsilon, case-insensitive ordering, nested JSON fields, trailing token rejection, FROM-only queries, OutputFormat roundtrip
- [x] **Docs**: Fixed README (~5MB not ~2MB), noted MATCHES=CONTAINS alias, fixed PROGRESS.md mmap references

---

## Design Decisions

| Decision             | Choice                                                  | Rationale                                                  |
| -------------------- | ------------------------------------------------------- | ---------------------------------------------------------- |
| Allocator strategy   | Arena for query parsing, read-into-buffer for log files | No per-object frees needed; arena drops everything at once |
| Lexer style          | Streaming (one token at a time)                         | Memory efficient, no intermediate token array              |
| Log parsing          | Zero-copy slices into file buffer                       | Core perf advantage of Zig                                 |
| Duration storage     | Nanoseconds (u64)                                       | Uniform, avoids float math, covers ms to days              |
| Temporal correlation | Sorted window scan                                      | Logs are usually time-ordered; exploit that                |

| File I/O | Zig 0.16 `Io.Dir`/`File.Reader` API | New structured I/O in 0.16; `std.fs.cwd()` removed |
| Log format detection | First-line heuristic (JSON/logfmt/syslog) | Fast, zero-alloc, reliable for common formats |
| Relative paths | Parser combines adjacent tokens | Keeps lexer context-free; handles `testdata/app.json` |
| Temporal algorithm | Binary search on sorted anchor timestamps | O(n log m) — faster than brute-force O(n\*m) |
| Field resolution | Well-known fields → entry.fields → nested JSON | Tries `level`/`message`/`timestamp` first, then field scan |
| GROUP BY storage | `StringHashMap(ArrayList(usize))` | Group key → sorted entry indices, single-field fast path |
| String comparison | Case-insensitive via `std.ascii.toLower` | Pragmatic for log level matching ("ERROR" = "error") |
| Numeric coercion | Parse-on-compare for string fields | `status >= 500` works even when status stored as string |
| Output formatting | Dedicated Formatter struct | Decouples display logic from query engine |
| JSON output | NDJSON (one object per line) | Pipe-friendly, `jq`-compatible |
| TTY detection | `Io.File.isTty(.stdout(), io)` | Zig 0.16 moved isatty to `Io.File` |
| Follow polling | 200ms `Io.sleep` with `Duration.fromMilliseconds` | Simple, portable, handles log rotation via size check |
| Follow memory | Per-iteration `ArenaAllocator` over `page_allocator` | Prevents unbounded memory growth in long-running follows |
| CLI structure | Separate `cli.zig` module | Clean separation; testable independently |
| Error messages | Caret highlighting + human-friendly names | Better DX than raw Zig error names |
| Man page | troff format (`doc/zeal.1`) | Standard Unix convention, `man -l` compatible |
| CI | GitHub Actions with cross-compile matrix | Validates Linux + macOS, 4 cross-compile targets |
| Benchmarks | Shell script with Python data generator | Reproducible, no external dependencies beyond jq |

---

## Current Status

**Phase 6 complete — all phases done.** Zeal is a fully functional structured log query language + runtime.

### Binary size

- ReleaseFast: ~4.6 MB static binary (no dependencies)

### Source files

- 11 Zig source modules (`src/`)
- 3 shell completion scripts (`completions/`)
- 1 man page (`doc/zeal.1`)
- 1 CI workflow (`.github/workflows/ci.yml`)
- 1 benchmark script (`bench/bench.sh`)
- 3 test data files (`testdata/`)

### Test coverage

- 70 unit tests across all modules
- End-to-end smoke tests for every feature

### Quick examples

```bash
# Filter
zeal 'FROM testdata/app.json WHERE level = "error"'

# Temporal correlation
zeal 'FROM testdata/app.json WHERE level = "error" WITHIN 5s OF level = "warn"'

# GROUP BY + JSON output
zeal --format json 'FROM testdata/app.json WHERE level = "error" GROUP BY request_id'

# Follow mode
zeal --follow 'FROM /var/log/app.log WHERE level = "error"'

# Explain
zeal --explain 'FROM testdata/app.json WHERE status >= 500 GROUP BY host'

# Benchmarks
./bench/bench.sh 10000
```
