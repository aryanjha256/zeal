#!/usr/bin/env bash
# bench.sh — Benchmark zeal vs grep+jq pipelines
#
# Usage: ./bench/bench.sh [lines]
# Default: 10000 lines

set -uo pipefail

NUM_LINES=${1:-10000}
TMPLOG=$(mktemp /tmp/bench_XXXXXX.json)
ZEAL=./zig-out/bin/zeal
REPEATS=5

cleanup() { rm -f "$TMPLOG"; }
trap cleanup EXIT

# ── Generate test data ───────────────────────────────────────────────

echo "Generating $NUM_LINES JSON log entries..."

python3 -c "
import json, random, sys
levels = ['info', 'warn', 'error', 'debug', 'fatal']
msgs = [
    'Request completed',
    'Connection timeout',
    'Database unreachable',
    'Health check passed',
    'Slow query detected',
    'Request failed',
    'Cache miss',
    'Authentication failed',
    'Rate limit exceeded',
    'Server started',
]
for i in range($NUM_LINES):
    h = 10 + i // 3600
    m = (i // 60) % 60
    s = i % 60
    entry = {
        'timestamp': f'2024-01-15T{h:02d}:{m:02d}:{s:02d}Z',
        'level': random.choice(levels),
        'message': random.choice(msgs),
        'request_id': f'req-{random.randint(1, 500):04d}',
        'status': random.choice([200, 200, 200, 200, 400, 404, 500, 502, 503]),
        'latency_ms': random.randint(1, 5000),
        'host': random.choice(['web-1', 'web-2', 'web-3', 'api-1', 'api-2']),
    }
    print(json.dumps(entry, separators=(',', ':')))
" > "$TMPLOG"

echo "Log file: $TMPLOG ($(du -h "$TMPLOG" | cut -f1))"
echo ""

# ── Check prerequisites ─────────────────────────────────────────────

if [ ! -x "$ZEAL" ]; then
    echo "Building zeal (ReleaseFast)..."
    zig build -Doptimize=ReleaseFast
fi

if ! command -v jq &> /dev/null; then
    echo "Warning: jq not found, skipping jq benchmarks"
    HAS_JQ=0
else
    HAS_JQ=1
fi

if ! command -v hyperfine &> /dev/null; then
    USE_HYPERFINE=0
    echo "Note: hyperfine not found, using basic timing"
else
    USE_HYPERFINE=1
fi

echo "════════════════════════════════════════════════════════════════"
echo " Benchmark: $NUM_LINES JSON log entries × $REPEATS runs"
echo "════════════════════════════════════════════════════════════════"
echo ""

# ── Benchmark function ───────────────────────────────────────────────

time_cmd() {
    local label=$1
    shift
    local cmd="$@"

    if [ "$USE_HYPERFINE" -eq 1 ]; then
        echo "[$label]"
        hyperfine --warmup 2 --runs "$REPEATS" --export-json /dev/null "$cmd" 2>&1 | tail -1
        echo ""
    else
        echo "[$label]"
        local total=0
        for i in $(seq 1 $REPEATS); do
            local start=$(date +%s%N)
            eval "$cmd" > /dev/null 2>&1 || true
            local end=$(date +%s%N)
            local elapsed=$(( (end - start) / 1000000 ))
            total=$((total + elapsed))
        done
        local avg=$((total / REPEATS))
        echo "  avg: ${avg}ms (${REPEATS} runs)"
        echo ""
    fi
}

# ── Test 1: Simple filter (level = "error") ──────────────────────────

echo "── Test 1: Filter level = \"error\" ──────────────────────────────"
echo ""

time_cmd "zeal" "$ZEAL --format raw 'FROM $TMPLOG WHERE level = \"error\"'"

if [ "$HAS_JQ" -eq 1 ]; then
    time_cmd "grep+jq" "grep '\"level\":\"error\"' $TMPLOG | jq -c ."
    time_cmd "jq-only" "jq -c 'select(.level == \"error\")' $TMPLOG"
fi

time_cmd "grep" "grep '\"level\":\"error\"' $TMPLOG"

# ── Test 2: Numeric comparison (status >= 500) ───────────────────────

echo "── Test 2: Filter status >= 500 ─────────────────────────────────"
echo ""

time_cmd "zeal" "$ZEAL --format raw 'FROM $TMPLOG WHERE status >= 500'"

if [ "$HAS_JQ" -eq 1 ]; then
    time_cmd "jq" "jq -c 'select(.status >= 500)' $TMPLOG"
fi

# ── Test 3: Compound filter ──────────────────────────────────────────

echo "── Test 3: level = \"error\" AND status >= 500 ───────────────────"
echo ""

time_cmd "zeal" "$ZEAL --format raw 'FROM $TMPLOG WHERE level = \"error\" AND status >= 500'"

if [ "$HAS_JQ" -eq 1 ]; then
    time_cmd "jq" "jq -c 'select(.level == \"error\" and .status >= 500)' $TMPLOG"
fi

# ── Test 4: CONTAINS ─────────────────────────────────────────────────

echo "── Test 4: message CONTAINS \"timeout\" ──────────────────────────"
echo ""

time_cmd "zeal" "$ZEAL --format raw 'FROM $TMPLOG WHERE message CONTAINS \"timeout\"'"

if [ "$HAS_JQ" -eq 1 ]; then
    time_cmd "jq" "jq -c 'select(.message | test(\"timeout\"; \"i\"))' $TMPLOG"
fi

time_cmd "grep -i" "grep -i 'timeout' $TMPLOG"

# ── Test 5: COUNT ────────────────────────────────────────────────────

echo "── Test 5: COUNT level = \"error\" ───────────────────────────────"
echo ""

time_cmd "zeal" "$ZEAL --format raw 'FROM $TMPLOG WHERE level = \"error\" SHOW COUNT'"

if [ "$HAS_JQ" -eq 1 ]; then
    time_cmd "jq+wc" "jq -c 'select(.level == \"error\")' $TMPLOG | wc -l"
fi

time_cmd "grep+wc" "grep -c '\"level\":\"error\"' $TMPLOG"

echo "════════════════════════════════════════════════════════════════"
echo " Done"
echo "════════════════════════════════════════════════════════════════"
