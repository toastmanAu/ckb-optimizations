#!/bin/bash
# Run CKB benchmark with baseline vs optimized RocksDB configs and compare results.
#
# This swaps the db-options file and cache settings between runs, keeping
# everything else identical. Results are appended to EXPERIMENT.md.
#
# Usage:
#   ./run-comparison.sh              # Run both configs and compare
#   ./run-comparison.sh --baseline   # Run baseline only
#   ./run-comparison.sh --optimized  # Run optimized only
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CKB_DIR="/home/phill/nervos_optimizations/ckb"
REPORT_DIR="/home/phill/nervos_optimizations/benchmarks/reports"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
EXPERIMENT_LOG="$SCRIPT_DIR/EXPERIMENT.md"

mkdir -p "$REPORT_DIR"

RUN_BASELINE=1
RUN_OPTIMIZED=1
for arg in "$@"; do
    case "$arg" in
        --baseline)  RUN_OPTIMIZED=0 ;;
        --optimized) RUN_BASELINE=0 ;;
    esac
done

# ---------------------------------------------------------------------------
# Config swapping helpers
# ---------------------------------------------------------------------------
BASELINE_OPTS="$CKB_DIR/resource/default.db-options"
OPTIMIZED_OPTS="$CKB_DIR/resource/optimized.db-options"
CKB_TOML="$CKB_DIR/resource/ckb.toml"

# Save original ckb.toml
cp "$CKB_TOML" "$CKB_TOML.bak"

apply_baseline() {
    # Ensure ckb.toml points to default options with default cache
    sed -i 's|options_file = "optimized.db-options"|options_file = "default.db-options"|' "$CKB_TOML"
    sed -i 's|^cache_size = 2147483648|cache_size = 268435456|' "$CKB_TOML"
    # Restore default store cache sizes
    sed -i 's|^header_cache_size.*=.*8192|header_cache_size          = 4096|' "$CKB_TOML"
    sed -i 's|^cell_data_cache_size.*=.*4096|cell_data_cache_size       = 128|' "$CKB_TOML"
    sed -i 's|^block_proposals_cache_size.*=.*256|block_proposals_cache_size = 30|' "$CKB_TOML"
    sed -i 's|^block_tx_hashes_cache_size.*=.*256|block_tx_hashes_cache_size = 30|' "$CKB_TOML"
    sed -i 's|^block_uncles_cache_size.*=.*128|block_uncles_cache_size    = 30|' "$CKB_TOML"
    echo "  Config: BASELINE (default.db-options, 256MB cache)"
}

apply_optimized() {
    sed -i 's|options_file = "default.db-options"|options_file = "optimized.db-options"|' "$CKB_TOML"
    sed -i 's|^cache_size = 268435456|cache_size = 2147483648|' "$CKB_TOML"
    sed -i 's|^header_cache_size.*=.*4096|header_cache_size          = 8192|' "$CKB_TOML"
    sed -i 's|^cell_data_cache_size.*=.*128|cell_data_cache_size       = 4096|' "$CKB_TOML"
    sed -i 's|^block_proposals_cache_size.*=.*30|block_proposals_cache_size = 256|' "$CKB_TOML"
    sed -i 's|^block_tx_hashes_cache_size.*=.*30|block_tx_hashes_cache_size = 256|' "$CKB_TOML"
    sed -i 's|^block_uncles_cache_size.*=.*30|block_uncles_cache_size    = 128|' "$CKB_TOML"
    echo "  Config: OPTIMIZED (optimized.db-options, 2GB cache)"
}

restore_config() {
    cp "$CKB_TOML.bak" "$CKB_TOML"
}
trap restore_config EXIT

# ---------------------------------------------------------------------------
# Run benchmark
# ---------------------------------------------------------------------------
run_bench() {
    local label="$1"
    local report="$REPORT_DIR/ckb-rocksdb-$label-$TIMESTAMP.md"
    local log="$REPORT_DIR/ckb-rocksdb-$label-$TIMESTAMP.log"

    echo ""
    echo "==> Running CKB benchmarks ($label)..."
    echo "    Report: $report"

    pushd "$CKB_DIR" > /dev/null

    # Run with CI-sized inputs for speed
    if ! cargo bench -p ckb-benches --bench bench_main --features ci 2>&1 | tee "$log"; then
        echo "WARNING: bench exited non-zero"
    fi

    popd > /dev/null

    # Copy the auto-generated report if the runner script is available
    if [ -x "/home/phill/nervos_optimizations/benchmarks/run-ckb-bench.sh" ]; then
        /home/phill/nervos_optimizations/benchmarks/run-ckb-bench.sh --parse-only > /dev/null 2>&1 || true
        local latest=$(ls -t "$REPORT_DIR"/ckb-node-report-*.md 2>/dev/null | head -1)
        if [ -n "$latest" ]; then
            cp "$latest" "$report"
        fi
    fi

    echo "==> $label benchmark complete"
}

# ---------------------------------------------------------------------------
# Execute
# ---------------------------------------------------------------------------
echo "================================================================"
echo "  RocksDB Tuning Comparison Benchmark"
echo "  $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "================================================================"

if [ "$RUN_BASELINE" -eq 1 ]; then
    echo ""
    echo "--- BASELINE ---"
    apply_baseline
    run_bench "baseline"
fi

if [ "$RUN_OPTIMIZED" -eq 1 ]; then
    echo ""
    echo "--- OPTIMIZED ---"
    apply_optimized
    run_bench "optimized"
fi

# ---------------------------------------------------------------------------
# Compare results
# ---------------------------------------------------------------------------
if [ "$RUN_BASELINE" -eq 1 ] && [ "$RUN_OPTIMIZED" -eq 1 ]; then
    BASELINE_LOG="$REPORT_DIR/ckb-rocksdb-baseline-$TIMESTAMP.log"
    OPTIMIZED_LOG="$REPORT_DIR/ckb-rocksdb-optimized-$TIMESTAMP.log"

    echo ""
    echo "================================================================"
    echo "  Comparison Summary"
    echo "================================================================"

    # Extract timing from criterion output (look for "time:" lines)
    echo ""
    echo "Baseline timings:"
    grep -E "^(always_success|secp|overall|resolve)" "$BASELINE_LOG" 2>/dev/null | head -20 || echo "  (parse criterion output manually)"

    echo ""
    echo "Optimized timings:"
    grep -E "^(always_success|secp|overall|resolve)" "$OPTIMIZED_LOG" 2>/dev/null | head -20 || echo "  (parse criterion output manually)"

    echo ""
    echo "Detailed reports in $REPORT_DIR/"
    echo "Update $EXPERIMENT_LOG with results."
fi

echo ""
echo "=== Comparison complete ==="
