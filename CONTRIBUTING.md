# Contributing to Zeal

Thanks for your interest in contributing! Zeal is a small, focused tool and every contribution matters.

## Getting started

```bash
git clone https://github.com/aryanjha256/zeal.git
cd zeal
zig build        # debug build
zig build test   # run all tests
```

You need **Zig 0.16+** (nightly). Install it from <https://ziglang.org/download/>.

## Project structure

| Path                 | Purpose                                       |
| -------------------- | --------------------------------------------- |
| `src/lexer.zig`      | Streaming tokenizer (zero-copy)               |
| `src/parser.zig`     | Recursive-descent parser → AST                |
| `src/ast.zig`        | AST node types                                |
| `src/log_reader.zig` | File reader + line iterator                   |
| `src/log_parser.zig` | Format auto-detection (JSON / logfmt / plain) |
| `src/evaluator.zig`  | WHERE expression evaluator                    |
| `src/temporal.zig`   | Temporal correlation + GROUP BY               |
| `src/cli.zig`        | CLI argument parser                           |
| `src/formatter.zig`  | Output formatting (text / JSON / raw)         |
| `src/main.zig`       | CLI entry point                               |
| `src/root.zig`       | Library root (re-exports)                     |

## How to contribute

### Bug reports

Open an issue with:

- What you ran (command + input)
- What you expected
- What happened instead
- Zig version (`zig version`)

### Feature requests

Open an issue describing the use case. The more concrete (with example queries / log lines), the better.

### Pull requests

1. Fork & create a branch from `main`
2. Make your change
3. Add or update tests (every `.zig` file has `test` blocks at the bottom)
4. Run `zig build test` — all tests must pass
5. Run `zig fmt src/` — code must be formatted
6. Open a PR with a clear description

### Code style

- Follow `zig fmt` formatting (enforced in CI)
- Use doc comments (`///`) on public declarations
- Keep functions short and composable
- Prefer zero-copy slices over allocations
- Test edge cases (empty input, missing fields, malformed data)

### Commit messages

Use conventional-ish messages:

```
fix: handle empty JSON objects in log_parser
feat: add MATCHES operator with regex support
test: add timezone offset parsing tests
docs: update README with new examples
```

## Running benchmarks

```bash
zig build -Doptimize=ReleaseFast
./bench/bench.sh 10000
```

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
