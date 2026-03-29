#!/bin/bash
# Run molecule serialization benchmarks (Criterion) and generate report.
#
# Usage:
#   ./run-molecule-bench.sh              # Run all benchmarks
#   ./run-molecule-bench.sh --parse-only # Parse existing criterion results only
set -euo pipefail

MOLECULE_DIR="/home/phill/nervos_optimizations/molecule"
BENCH_DIR="$MOLECULE_DIR/benches"
REPORT_DIR="/home/phill/nervos_optimizations/benchmarks/reports"
CRITERION_DIR="$BENCH_DIR/target/criterion"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT="$REPORT_DIR/molecule-bench-$TIMESTAMP.md"
LOG_FILE="$REPORT_DIR/molecule-bench-run-$TIMESTAMP.log"

mkdir -p "$REPORT_DIR"

PARSE_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --parse-only) PARSE_ONLY=1 ;;
    esac
done

# ---------------------------------------------------------------------------
# JSON helper
# ---------------------------------------------------------------------------
json_extract() {
    local file="$1"
    local path="$2"
    if command -v jq &>/dev/null; then
        jq -r ".$path" "$file" 2>/dev/null || echo "N/A"
    elif command -v python3 &>/dev/null; then
        python3 -c "
import json, sys
try:
    d = json.load(open('$file'))
    keys = '$path'.split('.')
    v = d
    for k in keys:
        v = v[k]
    print(v)
except Exception:
    print('N/A')
" 2>/dev/null || echo "N/A"
    else
        echo "N/A"
    fi
}

format_ns() {
    local ns="$1"
    if [ "$ns" = "N/A" ]; then echo "N/A"; return; fi
    python3 -c "
v = float('$ns')
if v >= 1e9:    print(f'{v/1e9:.3f} s')
elif v >= 1e6:  print(f'{v/1e6:.3f} ms')
elif v >= 1e3:  print(f'{v/1e3:.3f} us')
else:           print(f'{v:.1f} ns')
" 2>/dev/null || echo "${ns} ns"
}

# ---------------------------------------------------------------------------
# System info
# ---------------------------------------------------------------------------
echo "=== Molecule Benchmark Runner ==="
echo "Date:   $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "Host:   $(hostname 2>/dev/null || echo unknown)"
echo "CPU:    $(lscpu 2>/dev/null | grep 'Model name' | head -1 | sed 's/.*:\s*//' || echo unknown)"
echo "Rust:   $(rustc --version 2>/dev/null || echo unknown)"
echo ""

HOST=$(hostname 2>/dev/null || echo "unknown")
KERNEL=$(uname -r 2>/dev/null || echo "unknown")
CPU=$(lscpu 2>/dev/null | grep "Model name" | head -1 | sed 's/.*:\s*//' || echo "unknown")
RUST_VERSION=$(rustc --version 2>/dev/null || echo "unknown")

# ---------------------------------------------------------------------------
# Run benchmarks
# ---------------------------------------------------------------------------
if [ "$PARSE_ONLY" -eq 0 ]; then
    echo "==> Running molecule Criterion benchmarks..."
    echo "    Log: $LOG_FILE"
    pushd "$BENCH_DIR" > /dev/null
    if ! cargo bench 2>&1 | tee "$LOG_FILE"; then
        echo "WARNING: cargo bench exited non-zero."
    fi
    popd > /dev/null
else
    echo "==> Parse-only mode."
fi

# ---------------------------------------------------------------------------
# Parse criterion results
# ---------------------------------------------------------------------------
if [ ! -d "$CRITERION_DIR" ]; then
    echo "ERROR: No criterion results at $CRITERION_DIR"
    echo "Run benchmarks first (without --parse-only)."
    exit 1
fi

declare -a BENCH_NAMES=()
declare -A BENCH_MEAN=()
declare -A BENCH_MEDIAN=()
declare -A BENCH_STDDEV=()

while IFS= read -r -d '' efile; do
    rel="${efile#$CRITERION_DIR/}"
    bench_id="${rel%/new/estimates.json}"
    BENCH_NAMES+=("$bench_id")
    BENCH_MEAN["$bench_id"]=$(json_extract "$efile" "mean.point_estimate")
    BENCH_MEDIAN["$bench_id"]=$(json_extract "$efile" "median.point_estimate")
    BENCH_STDDEV["$bench_id"]=$(json_extract "$efile" "std_dev.point_estimate")
done < <(find "$CRITERION_DIR" -path "*/new/estimates.json" -print0 2>/dev/null | sort -z)

if [ ${#BENCH_NAMES[@]} -eq 0 ]; then
    echo "ERROR: No benchmark results found."
    exit 1
fi

echo "==> Found ${#BENCH_NAMES[@]} benchmark result(s). Generating report..."

# ---------------------------------------------------------------------------
# Generate report
# ---------------------------------------------------------------------------
{
    cat <<EOF
# Molecule Serialization Benchmark Report

**Date:** $(date '+%Y-%m-%d %H:%M:%S %Z')
**Host:** $HOST ($KERNEL)
**CPU:** $CPU
**Rust:** $RUST_VERSION
**Benchmark Framework:** Criterion 0.5

---

## Results

EOF

    # Group by benchmark group prefix
    GROUPS_LIST=$(for name in "${BENCH_NAMES[@]}"; do echo "$name" | cut -d'/' -f1; done | sort -u)

    for group in $GROUPS_LIST; do
        display_group=$(echo "$group" | tr '_' ' ')
        echo "### $display_group"
        echo ""
        echo "| Benchmark | Mean | Median | Std Dev |"
        echo "|-----------|------|--------|---------|"

        for name in "${BENCH_NAMES[@]}"; do
            if [[ "$name" == "$group"* ]]; then
                short_name=$(echo "$name" | sed "s|^$group/||")
                echo "| $short_name | $(format_ns "${BENCH_MEAN[$name]}") | $(format_ns "${BENCH_MEDIAN[$name]}") | $(format_ns "${BENCH_STDDEV[$name]}") |"
            fi
        done
        echo ""
    done

    echo "---"
    echo ""
    echo "## Summary"
    echo ""
    echo "| Category | Count |"
    echo "|----------|-------|"
    echo "| Total benchmarks | ${#BENCH_NAMES[@]} |"
    for group in $GROUPS_LIST; do
        count=0
        for name in "${BENCH_NAMES[@]}"; do
            if [[ "$name" == "$group"* ]]; then ((count++)) || true; fi
        done
        echo "| $group | $count |"
    done
    echo ""

    echo "---"
    echo ""
    echo "*Report generated by run-molecule-bench.sh at $(date '+%Y-%m-%d %H:%M:%S %Z')*"

} > "$REPORT"

echo "==> Report written to: $REPORT"
echo ""
head -10 "$REPORT"
echo "..."
echo ""
echo "=== Molecule benchmark run complete ==="
