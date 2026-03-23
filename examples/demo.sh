#!/usr/bin/env bash
# demo.sh — Quick tour of Zeal's features
#
# Usage: ./examples/demo.sh
# Requires: zeal binary at ./zig-out/bin/zeal (run `zig build` first)

set -uo pipefail

ZEAL=./zig-out/bin/zeal
DEMO=./examples/demo.json

if [ ! -x "$ZEAL" ]; then
    echo "Building zeal..."
    zig build -Doptimize=ReleaseFast 2>/dev/null || zig build
fi

if [ ! -f "$DEMO" ]; then
    echo "error: $DEMO not found (run from repo root)"
    exit 1
fi

# Colors
BOLD='\033[1m'
DIM='\033[90m'
RESET='\033[0m'
CYAN='\033[36m'

demo() {
    echo ""
    echo -e "${BOLD}${CYAN}$ $1${RESET}"
    echo -e "${DIM}────────────────────────────────────────${RESET}"
    eval "$1"
    echo ""
    read -r -p "  Press Enter for next example..." < /dev/tty
}

echo ""
echo -e "${BOLD}⚡ Zeal Demo${RESET}"
echo -e "${DIM}A structured log query language — like jq, but for logs.${RESET}"
echo ""
echo "Using: $DEMO ($(wc -l < "$DEMO") entries)"

demo "$ZEAL 'FROM $DEMO WHERE level = \"error\"'"

demo "$ZEAL 'FROM $DEMO WHERE status >= 500 SHOW COUNT'"

demo "$ZEAL 'FROM $DEMO WHERE level = \"error\" WITHIN 5s OF level = \"warn\"'"

demo "$ZEAL 'FROM $DEMO WHERE level = \"error\" GROUP BY host'"

demo "$ZEAL --format json 'FROM $DEMO WHERE level = \"error\" SHOW LAST 3'"

demo "$ZEAL --explain 'FROM $DEMO WHERE level = \"error\" WITHIN 5s OF level = \"warn\" GROUP BY host'"

demo "$ZEAL 'FROM $DEMO WHERE message CONTAINS \"timeout\" OR message CONTAINS \"unreachable\"'"

echo ""
echo -e "${BOLD}Done!${RESET} See more at: https://github.com/aryanjha256/zeal"
echo ""
