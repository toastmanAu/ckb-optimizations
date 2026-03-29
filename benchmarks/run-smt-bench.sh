#!/bin/bash
# Run sparse-merkle-tree benchmarks (Criterion + comprehensive report).
#
# Usage:
#   ./run-smt-bench.sh                # Run all benchmarks
#   ./run-smt-bench.sh --report-only  # Generate report only (skip Criterion stats)
#   ./run-smt-bench.sh --nostd        # Also run nostd-runner cycle counting (needs ckb-debugger)
set -euo pipefail

SMT_DIR="/home/phill/nervos_optimizations/sparse-merkle-tree"
REPORT_DIR="/home/phill/nervos_optimizations/benchmarks/reports"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$REPORT_DIR/smt-bench-run-$TIMESTAMP.log"

mkdir -p "$REPORT_DIR"

REPORT_ONLY=0
RUN_NOSTD=0
for arg in "$@"; do
    case "$arg" in
        --report-only) REPORT_ONLY=1 ;;
        --nostd)       RUN_NOSTD=1 ;;
    esac
done

# ---------------------------------------------------------------------------
# System info
# ---------------------------------------------------------------------------
echo "=== SMT Benchmark Runner ==="
echo "Date:   $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "Host:   $(hostname 2>/dev/null || echo unknown)"
echo "CPU:    $(lscpu 2>/dev/null | grep 'Model name' | head -1 | sed 's/.*:\s*//' || echo unknown)"
echo "Rust:   $(rustc --version 2>/dev/null || echo unknown)"
echo ""

# ---------------------------------------------------------------------------
# Run comprehensive benchmark (generates markdown report)
# ---------------------------------------------------------------------------
pushd "$SMT_DIR" > /dev/null

if [ "$REPORT_ONLY" -eq 1 ]; then
    echo "==> Report-only mode: generating SMT comprehensive report..."
    SMT_REPORT_ONLY=1 cargo bench --bench comprehensive_benchmark 2>&1 | tee "$LOG_FILE" || true
else
    echo "==> Running SMT comprehensive benchmark (Criterion + report)..."
    echo "    Log: $LOG_FILE"
    if ! cargo bench --bench comprehensive_benchmark 2>&1 | tee "$LOG_FILE"; then
        echo "WARNING: comprehensive_benchmark exited non-zero."
    fi

    echo ""
    echo "==> Running original smt_benchmark..."
    cargo bench --bench smt_benchmark 2>&1 | tee -a "$LOG_FILE" || true

    echo ""
    echo "==> Running store_counter_benchmark..."
    cargo bench --bench store_counter_benchmark 2>&1 | tee -a "$LOG_FILE" || true
fi

popd > /dev/null

# ---------------------------------------------------------------------------
# Nostd runner (CKB-VM cycle counting) -- optional
# ---------------------------------------------------------------------------
if [ "$RUN_NOSTD" -eq 1 ]; then
    NOSTD_DIR="$SMT_DIR/src/nostd-runner"

    if ! command -v ckb-debugger &>/dev/null; then
        echo ""
        echo "WARNING: ckb-debugger not found in PATH. Skipping nostd cycle counting."
        echo "Install with: cargo install ckb-debugger"
    elif [ ! -d "$NOSTD_DIR" ]; then
        echo ""
        echo "WARNING: nostd-runner directory not found. Skipping."
    else
        echo ""
        echo "==> Running nostd-runner cycle counting benchmarks..."

        pushd "$NOSTD_DIR" > /dev/null

        NOSTD_REPORT="$REPORT_DIR/smt-nostd-cycles-$TIMESTAMP.md"
        {
            echo "# SMT nostd-runner Cycle Counts"
            echo ""
            echo "**Date:** $(date '+%Y-%m-%d %H:%M:%S %Z')"
            echo ""
            echo "| Tree Size | Leaves | Cycles |"
            echo "|-----------|--------|--------|"

            for count in 16 256 1024 16384 131072; do
                for leaves in 1 10 40; do
                    if [ "$count" -lt "$leaves" ]; then continue; fi
                    echo "Running SMT_COUNT=$count SMT_LEAVES=$leaves..." >&2
                    result=$(make SMT_COUNT=$count SMT_LEAVES=$leaves test 2>&1 | grep -oE '[0-9]+ K' | tail -1 || echo "N/A")
                    echo "| $count | $leaves | $result cycles |"
                done
            done
        } > "$NOSTD_REPORT" 2>"$REPORT_DIR/smt-nostd-$TIMESTAMP.log"

        echo "==> Nostd cycle report: $NOSTD_REPORT"
        popd > /dev/null
    fi
fi

# ---------------------------------------------------------------------------
# Check for generated report
# ---------------------------------------------------------------------------
REPORT_FILE="$REPORT_DIR/smt-report.md"
if [ -f "$REPORT_FILE" ]; then
    echo ""
    echo "==> Report available at: $REPORT_FILE"
    echo ""
    head -20 "$REPORT_FILE"
    echo "..."
else
    echo ""
    echo "NOTE: Report file not found at $REPORT_FILE"
    echo "The comprehensive_benchmark should generate it."
fi

# ---------------------------------------------------------------------------
# Criterion results
# ---------------------------------------------------------------------------
CRITERION_DIR="$SMT_DIR/target/criterion"
if [ -d "$CRITERION_DIR" ]; then
    COUNT=$(find "$CRITERION_DIR" -path "*/new/estimates.json" -print 2>/dev/null | wc -l)
    echo ""
    echo "==> Found $COUNT Criterion result sets in $CRITERION_DIR"
fi

echo ""
echo "=== SMT benchmark run complete ==="
