#!/bin/bash
# Quick CKB benchmarks using CI-sized transaction counts for fast iteration.
#
# This is a thin wrapper around run-ckb-bench.sh that passes --ci mode,
# which activates the "ci" feature flag (always_success: 5 txs, secp: 2 txs,
# overall: 2 txs, resolve: 10 cells).
#
# Usage:
#   ./run-ckb-bench-quick.sh              # Run quick benchmarks and generate report
#   ./run-ckb-bench-quick.sh --parse-only # Parse existing criterion results only
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_SCRIPT="$SCRIPT_DIR/run-ckb-bench.sh"

if [ ! -x "$MAIN_SCRIPT" ]; then
    echo "ERROR: Main benchmark script not found or not executable: $MAIN_SCRIPT"
    exit 1
fi

# Forward all arguments and add --ci flag
exec "$MAIN_SCRIPT" --ci "$@"
