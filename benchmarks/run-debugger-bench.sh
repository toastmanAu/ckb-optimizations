#!/bin/bash
# Run ckb-standalone-debugger profiling benchmarks.
#
# Measures execution overhead of debugger profiling modes (fast vs full,
# flamegraph, coverage, step-log) on test binaries.
#
# Usage:
#   ./run-debugger-bench.sh           # Build and run all profiling benchmarks
#   ./run-debugger-bench.sh --skip-build  # Skip cargo build step
set -euo pipefail

DEBUGGER_DIR="/home/phill/nervos_optimizations/ckb-standalone-debugger"
REPORT_DIR="/home/phill/nervos_optimizations/benchmarks/reports"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT="$REPORT_DIR/debugger-report-$TIMESTAMP.md"
LOG_FILE="$REPORT_DIR/debugger-bench-run-$TIMESTAMP.log"

mkdir -p "$REPORT_DIR"

SKIP_BUILD=0
for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=1 ;;
    esac
done

# ---------------------------------------------------------------------------
# System info
# ---------------------------------------------------------------------------
HOST=$(hostname 2>/dev/null || echo "unknown")
KERNEL=$(uname -r 2>/dev/null || echo "unknown")
CPU=$(lscpu 2>/dev/null | grep "Model name" | head -1 | sed 's/.*:\s*//' || echo "unknown")
RUST_VERSION=$(rustc --version 2>/dev/null || echo "unknown")
NPROC=$(nproc 2>/dev/null || echo "unknown")

echo "=== CKB Debugger Profiling Benchmark ==="
echo "Date:   $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "Host:   $HOST ($KERNEL)"
echo "CPU:    $CPU ($NPROC cores)"
echo "Rust:   $RUST_VERSION"
echo ""

# ---------------------------------------------------------------------------
# Build debugger
# ---------------------------------------------------------------------------
DEBUGGER_BIN="$DEBUGGER_DIR/target/release/ckb-debugger"
PPROF_BIN="$DEBUGGER_DIR/target/release/ckb-vm-pprof"

if [ "$SKIP_BUILD" -eq 0 ]; then
    echo "==> Building ckb-debugger (release)..."
    pushd "$DEBUGGER_DIR" > /dev/null
    cargo build --release -p ckb-debugger -p ckb-vm-pprof 2>&1 | tee "$LOG_FILE"
    popd > /dev/null
    echo "==> Build complete."
    echo ""
fi

if [ ! -x "$DEBUGGER_BIN" ]; then
    echo "ERROR: ckb-debugger binary not found at $DEBUGGER_BIN"
    echo "Run without --skip-build first."
    exit 1
fi

# ---------------------------------------------------------------------------
# Test programs
# ---------------------------------------------------------------------------
EXAMPLES_DIR="$DEBUGGER_DIR/ckb-debugger/examples"
PPROF_RES="$DEBUGGER_DIR/ckb-vm-pprof/res"

# Use the fib program as primary benchmark (small, deterministic)
# And bench_pairing as a heavier workload
declare -a TEST_BINS=()
declare -a TEST_NAMES=()

for prog in fib; do
    if [ -f "$EXAMPLES_DIR/$prog" ]; then
        TEST_BINS+=("$EXAMPLES_DIR/$prog")
        TEST_NAMES+=("$prog (examples)")
    fi
done

for prog in fib abc sprintf; do
    if [ -f "$PPROF_RES/$prog" ]; then
        TEST_BINS+=("$PPROF_RES/$prog")
        TEST_NAMES+=("$prog (pprof)")
    fi
done

if [ ${#TEST_BINS[@]} -eq 0 ]; then
    echo "ERROR: No test binaries found."
    exit 1
fi

echo "==> Test binaries: ${TEST_NAMES[*]}"
echo ""

# ---------------------------------------------------------------------------
# Timing helper
# ---------------------------------------------------------------------------
time_cmd() {
    local start end elapsed
    start=$(date +%s%N)
    "$@" > /dev/null 2>&1
    local rc=$?
    end=$(date +%s%N)
    elapsed=$(( (end - start) / 1000000 ))  # milliseconds
    echo "$elapsed"
    return $rc
}

# Run N times, return median
median_of() {
    local n="$1"; shift
    local times=()
    for ((i=0; i<n; i++)); do
        t=$(time_cmd "$@") || true
        times+=("$t")
    done
    # Sort and pick middle
    IFS=$'\n' sorted=($(sort -n <<<"${times[*]}")); unset IFS
    echo "${sorted[$((n/2))]}"
}

# ---------------------------------------------------------------------------
# Benchmark each program in each mode
# ---------------------------------------------------------------------------
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

RUNS=5

declare -a RESULT_LINES=()

for idx in "${!TEST_BINS[@]}"; do
    bin="${TEST_BINS[$idx]}"
    name="${TEST_NAMES[$idx]}"

    echo "--- Benchmarking: $name ---"

    # Mode: fast (baseline)
    echo -n "  fast mode:       "
    fast_ms=$(median_of $RUNS "$DEBUGGER_BIN" --mode fast --max-cycles 100000000 --bin "$bin")
    echo "${fast_ms} ms"

    # Mode: full (no profiling features)
    echo -n "  full mode:       "
    full_ms=$(median_of $RUNS "$DEBUGGER_BIN" --mode full --max-cycles 100000000 --bin "$bin")
    echo "${full_ms} ms"

    # Mode: full + flamegraph
    echo -n "  full+flamegraph: "
    fg_ms=$(median_of $RUNS "$DEBUGGER_BIN" --mode full --max-cycles 100000000 --enable-flamegraph --flamegraph-output "$TMPDIR/fg.txt" --bin "$bin")
    echo "${fg_ms} ms"

    # Mode: full + coverage
    echo -n "  full+coverage:   "
    cov_ms=$(median_of $RUNS "$DEBUGGER_BIN" --mode full --max-cycles 100000000 --enable-coverage --coverage-output "$TMPDIR/cov.lcov" --bin "$bin")
    echo "${cov_ms} ms"

    # Mode: full + steplog
    echo -n "  full+steplog:    "
    step_ms=$(median_of $RUNS "$DEBUGGER_BIN" --mode full --max-cycles 100000000 --enable-steplog --steplog-output "$TMPDIR/step.log" --bin "$bin")
    echo "${step_ms} ms"

    # Capture cycles from a fast run
    cycles=$("$DEBUGGER_BIN" --mode fast --max-cycles 100000000 --bin "$bin" 2>&1 | grep -oE 'cycles: [0-9]+' | head -1 | grep -oE '[0-9]+' || echo "N/A")

    RESULT_LINES+=("$name|$cycles|$fast_ms|$full_ms|$fg_ms|$cov_ms|$step_ms")

    # Flamegraph size
    if [ -f "$TMPDIR/fg.txt" ]; then
        fg_size=$(wc -c < "$TMPDIR/fg.txt")
        echo "  flamegraph output: $(( fg_size / 1024 )) KB"
    fi

    echo ""
done

# ---------------------------------------------------------------------------
# ckb-vm-pprof benchmark
# ---------------------------------------------------------------------------
PPROF_LINES=()
if [ -x "$PPROF_BIN" ]; then
    echo "--- ckb-vm-pprof profiler ---"
    for prog in fib abc; do
        pprof_bin="$PPROF_RES/$prog"
        if [ ! -f "$pprof_bin" ]; then continue; fi
        echo -n "  pprof $prog: "
        pprof_ms=$(median_of $RUNS "$PPROF_BIN" --bin "$pprof_bin")
        echo "${pprof_ms} ms"
        PPROF_LINES+=("$prog|$pprof_ms")
    done
    echo ""
fi

# ---------------------------------------------------------------------------
# Generate report
# ---------------------------------------------------------------------------
{
    cat <<EOF
# CKB Debugger Profiling Benchmark Report

**Date:** $(date '+%Y-%m-%d %H:%M:%S %Z')
**Host:** $HOST ($KERNEL)
**CPU:** $CPU ($NPROC cores)
**Rust:** $RUST_VERSION
**Debugger:** $($DEBUGGER_BIN --version 2>&1 | head -1 || echo "unknown")
**Runs per measurement:** $RUNS (median)

---

## Profiling Mode Overhead

| Program | Cycles | Fast (ms) | Full (ms) | +Flamegraph (ms) | +Coverage (ms) | +StepLog (ms) |
|---------|--------|-----------|-----------|-------------------|----------------|----------------|
EOF

    for line in "${RESULT_LINES[@]}"; do
        IFS='|' read -r name cycles fast full fg cov step <<< "$line"
        echo "| $name | $cycles | $fast | $full | $fg | $cov | $step |"
    done

    echo ""
    echo "### Overhead Analysis"
    echo ""
    echo "| Program | Full vs Fast | Flamegraph vs Full | Coverage vs Full | StepLog vs Full |"
    echo "|---------|-------------|-------------------|-----------------|-----------------|"

    for line in "${RESULT_LINES[@]}"; do
        IFS='|' read -r name cycles fast full fg cov step <<< "$line"
        if [ "$fast" -gt 0 ] 2>/dev/null; then
            full_pct=$(python3 -c "print(f'{(($full/$fast)-1)*100:+.0f}%')" 2>/dev/null || echo "N/A")
        else
            full_pct="N/A"
        fi
        if [ "$full" -gt 0 ] 2>/dev/null; then
            fg_pct=$(python3 -c "print(f'{(($fg/$full)-1)*100:+.0f}%')" 2>/dev/null || echo "N/A")
            cov_pct=$(python3 -c "print(f'{(($cov/$full)-1)*100:+.0f}%')" 2>/dev/null || echo "N/A")
            step_pct=$(python3 -c "print(f'{(($step/$full)-1)*100:+.0f}%')" 2>/dev/null || echo "N/A")
        else
            fg_pct="N/A"; cov_pct="N/A"; step_pct="N/A"
        fi
        echo "| $name | $full_pct | $fg_pct | $cov_pct | $step_pct |"
    done

    if [ ${#PPROF_LINES[@]} -gt 0 ]; then
        echo ""
        echo "## ckb-vm-pprof Standalone Profiler"
        echo ""
        echo "| Program | Time (ms) |"
        echo "|---------|-----------|"
        for line in "${PPROF_LINES[@]}"; do
            IFS='|' read -r name ms <<< "$line"
            echo "| $name | $ms |"
        done
    fi

    echo ""
    echo "---"
    echo ""
    echo "## Notes"
    echo ""
    echo "- **Fast mode**: Minimal overhead execution (no analysis)"
    echo "- **Full mode**: Analysis-ready execution (instruction stepping)"
    echo "- **Flamegraph**: Call graph reconstruction with cycle attribution"
    echo "- **Coverage**: Line-level execution tracking (LCOV output)"
    echo "- **StepLog**: Full instruction trace (highest overhead expected)"
    echo ""
    echo "---"
    echo ""
    echo "*Report generated by run-debugger-bench.sh at $(date '+%Y-%m-%d %H:%M:%S %Z')*"

} > "$REPORT"

echo "==> Report written to: $REPORT"
echo ""
head -15 "$REPORT"
echo "..."
echo ""
echo "=== Debugger benchmark run complete ==="
