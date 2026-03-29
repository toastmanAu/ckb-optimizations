#!/bin/bash
# Run CKB-VM benchmarks (Criterion + markdown report generation).
#
# Usage:
#   ./run-vm-bench.sh              # Run all benchmarks and generate report
#   ./run-vm-bench.sh --report-only # Just collect results (skip Criterion statistical run)
#
# The vm_benchmark bench target generates both Criterion output AND a markdown report.
set -euo pipefail

VM_DIR="/home/phill/nervos_optimizations/ckb-vm"
REPORT_DIR="/home/phill/nervos_optimizations/benchmarks/reports"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$REPORT_DIR/vm-bench-run-$TIMESTAMP.log"

mkdir -p "$REPORT_DIR"

REPORT_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --report-only) REPORT_ONLY=1 ;;
    esac
done

# ---------------------------------------------------------------------------
# System info
# ---------------------------------------------------------------------------
echo "=== CKB-VM Benchmark Runner ==="
echo "Date:   $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "Host:   $(hostname 2>/dev/null || echo unknown)"
echo "CPU:    $(lscpu 2>/dev/null | grep 'Model name' | head -1 | sed 's/.*:\s*//' || echo unknown)"
echo "Rust:   $(rustc --version 2>/dev/null || echo unknown)"
echo ""

# ---------------------------------------------------------------------------
# Check test programs exist
# ---------------------------------------------------------------------------
for prog in simple64 trace64; do
    if [ ! -f "$VM_DIR/tests/programs/$prog" ]; then
        echo "WARNING: Test program $prog not found. Benchmarks may fail."
    fi
done

# ---------------------------------------------------------------------------
# Check for ASM support
# ---------------------------------------------------------------------------
HAS_ASM="unknown"
if grep -q 'has_asm' "$VM_DIR/build.rs" 2>/dev/null || grep -q 'has_asm' "$VM_DIR/Cargo.toml" 2>/dev/null; then
    HAS_ASM="detected in build config"
fi
echo "ASM support: $HAS_ASM"
echo ""

# ---------------------------------------------------------------------------
# Run benchmarks
# ---------------------------------------------------------------------------
pushd "$VM_DIR" > /dev/null

if [ "$REPORT_ONLY" -eq 0 ]; then
    echo "==> Running CKB-VM Criterion benchmarks..."
    echo "    Log: $LOG_FILE"

    if ! cargo bench --bench vm_benchmark 2>&1 | tee "$LOG_FILE"; then
        echo "WARNING: cargo bench exited non-zero. Check log."
    fi

    echo ""
    echo "==> Also running bits_benchmark..."
    cargo bench --bench bits_benchmark 2>&1 | tee -a "$LOG_FILE" || true
else
    echo "==> Report-only mode: running vm_benchmark for report generation..."
    cargo bench --bench vm_benchmark -- --test 2>&1 | tee "$LOG_FILE" || true
fi

popd > /dev/null

# ---------------------------------------------------------------------------
# Check for generated report
# ---------------------------------------------------------------------------
REPORT_FILE="$REPORT_DIR/ckb-vm-report.md"
if [ -f "$REPORT_FILE" ]; then
    echo ""
    echo "==> Report available at: $REPORT_FILE"
    echo ""
    head -20 "$REPORT_FILE"
    echo "..."
else
    echo ""
    echo "WARNING: Expected report not found at $REPORT_FILE"
    echo "The vm_benchmark target should generate it automatically."
fi

# ---------------------------------------------------------------------------
# Parse Criterion results if available
# ---------------------------------------------------------------------------
CRITERION_DIR="$VM_DIR/target/criterion"
if [ -d "$CRITERION_DIR" ]; then
    COUNT=$(find "$CRITERION_DIR" -path "*/new/estimates.json" -print 2>/dev/null | wc -l)
    echo ""
    echo "==> Found $COUNT Criterion result sets in $CRITERION_DIR"
    echo "    HTML report: $CRITERION_DIR/report/index.html"
fi

echo ""
echo "=== CKB-VM benchmark run complete ==="
