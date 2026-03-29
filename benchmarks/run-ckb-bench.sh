#!/bin/bash
# Run CKB node benchmarks (full release mode) and generate a comprehensive markdown report.
#
# Usage:
#   ./run-ckb-bench.sh              # Run benchmarks then generate report
#   ./run-ckb-bench.sh --parse-only # Skip benchmark run, parse existing criterion results
#
# Dependencies: bash, python3 (for JSON parsing; jq used if available)
set -euo pipefail

CKB_DIR="/home/phill/nervos_optimizations/ckb"
REPORT_DIR="/home/phill/nervos_optimizations/benchmarks/reports"
CRITERION_DIR="$CKB_DIR/target/criterion"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT="$REPORT_DIR/ckb-node-report-$TIMESTAMP.md"
LOG_FILE="$REPORT_DIR/bench-run-$TIMESTAMP.log"

PARSE_ONLY=0
BENCH_FEATURES=""
QUICK_MODE=0

for arg in "$@"; do
    case "$arg" in
        --parse-only) PARSE_ONLY=1 ;;
        --ci)         BENCH_FEATURES="--features ci"; QUICK_MODE=1 ;;
    esac
done

mkdir -p "$REPORT_DIR"

# ---------------------------------------------------------------------------
# JSON helper -- use jq if available, otherwise fall back to python3
# ---------------------------------------------------------------------------
json_extract() {
    local file="$1"
    local path="$2"   # dot-separated path, e.g. mean.point_estimate
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

# ---------------------------------------------------------------------------
# Human-readable time formatting
# ---------------------------------------------------------------------------
format_ns() {
    local ns="$1"
    if [ "$ns" = "N/A" ]; then
        echo "N/A"
        return
    fi
    python3 -c "
v = float('$ns')
if v >= 1e9:
    print(f'{v/1e9:.3f} s')
elif v >= 1e6:
    print(f'{v/1e6:.3f} ms')
elif v >= 1e3:
    print(f'{v/1e3:.3f} us')
else:
    print(f'{v:.1f} ns')
" 2>/dev/null || echo "${ns} ns"
}

# ---------------------------------------------------------------------------
# Step 1: Run benchmarks (unless --parse-only)
# ---------------------------------------------------------------------------
if [ "$PARSE_ONLY" -eq 0 ]; then
    echo "==> Running CKB Criterion benchmarks (release mode)..."
    echo "    Log: $LOG_FILE"
    echo "    This may take a long time for full-size benchmarks."
    pushd "$CKB_DIR" > /dev/null
    # cargo bench for the bench_main target; capture both stdout and stderr
    if ! cargo bench -p ckb-benches --bench bench_main $BENCH_FEATURES 2>&1 | tee "$LOG_FILE"; then
        echo "WARNING: cargo bench exited with non-zero status. Attempting to parse any available results."
    fi
    popd > /dev/null
    echo "==> Benchmark run complete."
else
    echo "==> Parse-only mode -- skipping benchmark run."
fi

# ---------------------------------------------------------------------------
# Step 2: Verify criterion output directory exists
# ---------------------------------------------------------------------------
if [ ! -d "$CRITERION_DIR" ]; then
    echo "ERROR: No criterion results found at $CRITERION_DIR"
    echo "Run the benchmarks first (without --parse-only)."
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 3: Gather system and project information
# ---------------------------------------------------------------------------
HOST=$(hostname 2>/dev/null || echo "unknown")
KERNEL=$(uname -r 2>/dev/null || echo "unknown")
CPU=$(lscpu 2>/dev/null | grep "Model name" | head -1 | sed 's/.*:\s*//' || echo "unknown")
CPU_CORES=$(nproc 2>/dev/null || echo "unknown")
MEMORY=$(free -h 2>/dev/null | awk '/^Mem:/{print $2}' || echo "unknown")
RUST_VERSION=$(rustc --version 2>/dev/null || echo "unknown")
CARGO_VERSION=$(cargo --version 2>/dev/null || echo "unknown")
CKB_VERSION=$(cd "$CKB_DIR" && git describe --tags --always 2>/dev/null || echo "unknown")
CKB_BRANCH=$(cd "$CKB_DIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
CKB_COMMIT=$(cd "$CKB_DIR" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")

# ---------------------------------------------------------------------------
# Step 4: Extract RocksDB and node configuration
# ---------------------------------------------------------------------------
DB_OPTIONS_FILE="$CKB_DIR/resource/default.db-options"
CKB_TOML_FILE="$CKB_DIR/resource/ckb.toml"

# Extract key RocksDB settings from default.db-options
extract_db_option() {
    local key="$1"
    grep -m1 "^${key}=" "$DB_OPTIONS_FILE" 2>/dev/null | cut -d'=' -f2 || echo "N/A"
}

DB_BYTES_PER_SYNC=$(extract_db_option "bytes_per_sync")
DB_MAX_BG_JOBS=$(extract_db_option "max_background_jobs")
DB_MAX_WAL=$(extract_db_option "max_total_wal_size")
DB_WRITE_BUF=$(extract_db_option "write_buffer_size")
DB_MIN_MERGE=$(extract_db_option "min_write_buffer_number_to_merge")
DB_MAX_WRITE_BUF_NUM=$(extract_db_option "max_write_buffer_number")
DB_LEVEL_DYN=$(extract_db_option "level_compaction_dynamic_level_bytes")

# Extract cache_size from ckb.toml
CKB_CACHE_SIZE=$(grep -m1 "^cache_size" "$CKB_TOML_FILE" 2>/dev/null | sed 's/[^0-9]//g' || echo "N/A")

human_bytes() {
    python3 -c "
v = int('$1') if '$1' != 'N/A' else 0
if v == 0: print('N/A')
elif v >= 1073741824: print(f'{v/1073741824:.0f} GB')
elif v >= 1048576: print(f'{v/1048576:.0f} MB')
elif v >= 1024: print(f'{v/1024:.0f} KB')
else: print(f'{v} B')
" 2>/dev/null || echo "$1"
}

# ---------------------------------------------------------------------------
# Step 5: Parse criterion results
# ---------------------------------------------------------------------------
# Collect all estimates.json files
declare -a BENCH_NAMES=()
declare -A BENCH_MEAN=()
declare -A BENCH_MEDIAN=()
declare -A BENCH_STDDEV=()
declare -A BENCH_CI_LO=()
declare -A BENCH_CI_HI=()

while IFS= read -r -d '' efile; do
    # Path: target/criterion/<group>/<name>/<param>/new/estimates.json
    # or:   target/criterion/<group>/<name>/new/estimates.json
    rel="${efile#$CRITERION_DIR/}"
    # strip trailing /new/estimates.json
    bench_id="${rel%/new/estimates.json}"

    BENCH_NAMES+=("$bench_id")
    BENCH_MEAN["$bench_id"]=$(json_extract "$efile" "mean.point_estimate")
    BENCH_MEDIAN["$bench_id"]=$(json_extract "$efile" "median.point_estimate")
    BENCH_STDDEV["$bench_id"]=$(json_extract "$efile" "std_dev.point_estimate")
    BENCH_CI_LO["$bench_id"]=$(json_extract "$efile" "mean.confidence_interval.lower_bound")
    BENCH_CI_HI["$bench_id"]=$(json_extract "$efile" "mean.confidence_interval.upper_bound")
done < <(find "$CRITERION_DIR" -path "*/new/estimates.json" -print0 2>/dev/null | sort -z)

if [ ${#BENCH_NAMES[@]} -eq 0 ]; then
    echo "ERROR: No benchmark results found in $CRITERION_DIR"
    exit 1
fi

echo "==> Found ${#BENCH_NAMES[@]} benchmark result(s). Generating report..."

# ---------------------------------------------------------------------------
# Step 6: Write the markdown report
# ---------------------------------------------------------------------------
{
    if [ "$QUICK_MODE" -eq 1 ]; then
        cat <<'BANNER'
> **QUICK MODE** -- CI-sized benchmarks with reduced transaction counts.
> Results are for iteration speed only and do NOT represent production throughput.

BANNER
    fi

    cat <<EOF
# CKB Node Performance Benchmark Report

**Date:** $(date '+%Y-%m-%d %H:%M:%S %Z')
**Host:** $HOST ($KERNEL)
**CPU:** $CPU ($CPU_CORES cores)
**Memory:** $MEMORY
**Rust:** $RUST_VERSION
**Cargo:** $CARGO_VERSION
**CKB Version:** $CKB_VERSION (branch: $CKB_BRANCH, commit: $CKB_COMMIT)

---

## Current Configuration

### RocksDB Settings (default.db-options)

| Parameter | Value | Raw |
|-----------|-------|-----|
| max_background_jobs | $DB_MAX_BG_JOBS | $DB_MAX_BG_JOBS |
| max_total_wal_size | $(human_bytes "$DB_MAX_WAL") | $DB_MAX_WAL |
| bytes_per_sync | $(human_bytes "$DB_BYTES_PER_SYNC") | $DB_BYTES_PER_SYNC |
| write_buffer_size | $(human_bytes "$DB_WRITE_BUF") | $DB_WRITE_BUF |
| min_write_buffer_number_to_merge | $DB_MIN_MERGE | $DB_MIN_MERGE |
| max_write_buffer_number | $DB_MAX_WRITE_BUF_NUM | $DB_MAX_WRITE_BUF_NUM |
| level_compaction_dynamic_level_bytes | $DB_LEVEL_DYN | $DB_LEVEL_DYN |

### Node Settings (ckb.toml)

| Parameter | Value | Raw |
|-----------|-------|-----|
| cache_size | $(human_bytes "$CKB_CACHE_SIZE") | $CKB_CACHE_SIZE |
EOF

    # Extract store cache settings
    grep -E "^(header_cache_size|cell_data_cache_size|block_proposals_cache_size|block_tx_hashes_cache_size|block_uncles_cache_size)" "$CKB_TOML_FILE" 2>/dev/null | while IFS='=' read -r key val; do
        key=$(echo "$key" | xargs)
        val=$(echo "$val" | xargs)
        echo "| $key | $val | $val |"
    done

    echo ""
    echo "---"
    echo ""
    echo "## Benchmark Results"
    echo ""

    # -----------------------------------------------------------------------
    # Group: always_success (process_block)
    # -----------------------------------------------------------------------
    echo "### Block Processing (always_success)"
    echo ""
    echo "These benchmarks process blocks containing only always-success script transactions."
    echo ""

    for scenario in "main_branch" "side_branch" "switch_fork"; do
        scenario_display=$(echo "$scenario" | tr '_' ' ')
        # Find matching benchmarks
        matching=()
        for name in "${BENCH_NAMES[@]}"; do
            if [[ "$name" == *"always_success ${scenario}"* ]] || [[ "$name" == *"always_success_${scenario}"* ]]; then
                matching+=("$name")
            fi
        done

        if [ ${#matching[@]} -gt 0 ]; then
            echo "#### Scenario: $scenario_display"
            echo ""
            echo "| Txs/Block | Mean | Median | Std Dev | CI (95%) | Throughput (tx/s) |"
            echo "|-----------|------|--------|---------|----------|-------------------|"
            for name in "${matching[@]}"; do
                # Extract tx count from the benchmark id (last path component is the param)
                txs=$(echo "$name" | grep -oE '[0-9]+$' || echo "?")
                mean_ns="${BENCH_MEAN[$name]}"
                median_ns="${BENCH_MEDIAN[$name]}"
                stddev_ns="${BENCH_STDDEV[$name]}"
                ci_lo="${BENCH_CI_LO[$name]}"
                ci_hi="${BENCH_CI_HI[$name]}"

                # Throughput: blocks have txs_size txs processed over 20 blocks (main_branch)
                # For main_branch: 20 blocks * txs_size txs each
                # For side_branch: 2 blocks * txs_size
                # For switch_fork: 2 blocks * txs_size (blocks 8,9 -> 2 blocks)
                blocks=20
                if [ "$scenario" = "side_branch" ]; then blocks=2; fi
                if [ "$scenario" = "switch_fork" ]; then blocks=2; fi

                throughput="N/A"
                if [ "$mean_ns" != "N/A" ] && [ "$txs" != "?" ]; then
                    throughput=$(python3 -c "
mean_s = float('$mean_ns') / 1e9
total_tx = $blocks * int('$txs')
if mean_s > 0:
    print(f'{total_tx / mean_s:,.0f}')
else:
    print('N/A')
" 2>/dev/null || echo "N/A")
                fi

                ci_fmt="N/A"
                if [ "$ci_lo" != "N/A" ] && [ "$ci_hi" != "N/A" ]; then
                    ci_fmt="[$(format_ns "$ci_lo"), $(format_ns "$ci_hi")]"
                fi

                echo "| $txs | $(format_ns "$mean_ns") | $(format_ns "$median_ns") | $(format_ns "$stddev_ns") | $ci_fmt | $throughput |"
            done
            echo ""
        fi
    done

    # -----------------------------------------------------------------------
    # Group: secp_2in2out (process_block)
    # -----------------------------------------------------------------------
    echo "### Signature Verification (secp_2in2out)"
    echo ""
    echo "These benchmarks process blocks with secp256k1 2-in-2-out transactions (real signature verification)."
    echo ""

    for scenario in "main_branch" "side_branch" "switch_fork"; do
        scenario_display=$(echo "$scenario" | tr '_' ' ')
        matching=()
        for name in "${BENCH_NAMES[@]}"; do
            if [[ "$name" == *"secp ${scenario}"* ]] || [[ "$name" == *"secp_${scenario}"* ]]; then
                matching+=("$name")
            fi
        done

        if [ ${#matching[@]} -gt 0 ]; then
            echo "#### Scenario: $scenario_display"
            echo ""
            echo "| Txs/Block | Mean | Median | Std Dev | CI (95%) | Throughput (verif/s) |"
            echo "|-----------|------|--------|---------|----------|----------------------|"
            for name in "${matching[@]}"; do
                txs=$(echo "$name" | grep -oE '[0-9]+$' || echo "?")
                mean_ns="${BENCH_MEAN[$name]}"
                median_ns="${BENCH_MEDIAN[$name]}"
                stddev_ns="${BENCH_STDDEV[$name]}"
                ci_lo="${BENCH_CI_LO[$name]}"
                ci_hi="${BENCH_CI_HI[$name]}"

                blocks=20
                if [ "$scenario" = "side_branch" ]; then blocks=2; fi
                if [ "$scenario" = "switch_fork" ]; then blocks=2; fi

                throughput="N/A"
                if [ "$mean_ns" != "N/A" ] && [ "$txs" != "?" ]; then
                    throughput=$(python3 -c "
mean_s = float('$mean_ns') / 1e9
total_tx = $blocks * int('$txs')
if mean_s > 0:
    print(f'{total_tx / mean_s:,.0f}')
else:
    print('N/A')
" 2>/dev/null || echo "N/A")
                fi

                ci_fmt="N/A"
                if [ "$ci_lo" != "N/A" ] && [ "$ci_hi" != "N/A" ]; then
                    ci_fmt="[$(format_ns "$ci_lo"), $(format_ns "$ci_hi")]"
                fi

                echo "| $txs | $(format_ns "$mean_ns") | $(format_ns "$median_ns") | $(format_ns "$stddev_ns") | $ci_fmt | $throughput |"
            done
            echo ""
        fi
    done

    # -----------------------------------------------------------------------
    # Group: resolve / check_resolve
    # -----------------------------------------------------------------------
    echo "### Cell Resolution (resolve)"
    echo ""
    echo "| Benchmark | Size | Mean | Median | Std Dev | CI (95%) | Iterations/s |"
    echo "|-----------|------|------|--------|---------|----------|--------------|"
    for name in "${BENCH_NAMES[@]}"; do
        if [[ "$name" == *"resolve"* ]]; then
            label=$(basename "$(dirname "$name")" 2>/dev/null || echo "$name")
            # Try to get a cleaner label
            if [[ "$name" == *"check_resolve"* ]]; then
                label="check_resolve"
            elif [[ "$name" == *"resolve/resolve"* ]]; then
                label="resolve"
            else
                label="$name"
            fi
            size=$(echo "$name" | grep -oE '[0-9]+$' || echo "?")
            mean_ns="${BENCH_MEAN[$name]}"
            median_ns="${BENCH_MEDIAN[$name]}"
            stddev_ns="${BENCH_STDDEV[$name]}"
            ci_lo="${BENCH_CI_LO[$name]}"
            ci_hi="${BENCH_CI_HI[$name]}"

            iter_per_s="N/A"
            if [ "$mean_ns" != "N/A" ]; then
                iter_per_s=$(python3 -c "
mean_s = float('$mean_ns') / 1e9
if mean_s > 0:
    print(f'{1.0/mean_s:,.1f}')
else:
    print('N/A')
" 2>/dev/null || echo "N/A")
            fi

            ci_fmt="N/A"
            if [ "$ci_lo" != "N/A" ] && [ "$ci_hi" != "N/A" ]; then
                ci_fmt="[$(format_ns "$ci_lo"), $(format_ns "$ci_hi")]"
            fi

            echo "| $label | $size | $(format_ns "$mean_ns") | $(format_ns "$median_ns") | $(format_ns "$stddev_ns") | $ci_fmt | $iter_per_s |"
        fi
    done
    echo ""

    # -----------------------------------------------------------------------
    # Group: overall (integration)
    # -----------------------------------------------------------------------
    echo "### Overall Integration"
    echo ""
    echo "Full integration benchmark: block assembly, tx pool submission, header verification, and block processing."
    echo ""
    echo "| Size | Mean | Median | Std Dev | CI (95%) | Blocks/s |"
    echo "|------|------|--------|---------|----------|----------|"
    for name in "${BENCH_NAMES[@]}"; do
        if [[ "$name" == *"overall"* ]]; then
            size=$(echo "$name" | grep -oE '[0-9]+$' || echo "?")
            mean_ns="${BENCH_MEAN[$name]}"
            median_ns="${BENCH_MEDIAN[$name]}"
            stddev_ns="${BENCH_STDDEV[$name]}"
            ci_lo="${BENCH_CI_LO[$name]}"
            ci_hi="${BENCH_CI_HI[$name]}"

            # overall processes 10 blocks per iteration
            blocks_per_s="N/A"
            if [ "$mean_ns" != "N/A" ]; then
                blocks_per_s=$(python3 -c "
mean_s = float('$mean_ns') / 1e9
if mean_s > 0:
    print(f'{10.0/mean_s:,.2f}')
else:
    print('N/A')
" 2>/dev/null || echo "N/A")
            fi

            ci_fmt="N/A"
            if [ "$ci_lo" != "N/A" ] && [ "$ci_hi" != "N/A" ]; then
                ci_fmt="[$(format_ns "$ci_lo"), $(format_ns "$ci_hi")]"
            fi

            echo "| $size | $(format_ns "$mean_ns") | $(format_ns "$median_ns") | $(format_ns "$stddev_ns") | $ci_fmt | $blocks_per_s |"
        fi
    done
    echo ""

    # -----------------------------------------------------------------------
    # Any benchmarks not yet categorized
    # -----------------------------------------------------------------------
    uncategorized=()
    for name in "${BENCH_NAMES[@]}"; do
        if [[ "$name" != *"always_success"* ]] && [[ "$name" != *"secp "* ]] && [[ "$name" != *"secp_"* ]] && [[ "$name" != *"resolve"* ]] && [[ "$name" != *"overall"* ]] && [[ "$name" != *"report"* ]]; then
            uncategorized+=("$name")
        fi
    done
    if [ ${#uncategorized[@]} -gt 0 ]; then
        echo "### Other Benchmarks"
        echo ""
        echo "| Benchmark | Mean | Median | Std Dev |"
        echo "|-----------|------|--------|---------|"
        for name in "${uncategorized[@]}"; do
            echo "| $name | $(format_ns "${BENCH_MEAN[$name]}") | $(format_ns "${BENCH_MEDIAN[$name]}") | $(format_ns "${BENCH_STDDEV[$name]}") |"
        done
        echo ""
    fi

    echo "---"
    echo ""

    # -----------------------------------------------------------------------
    # RocksDB Tuning Opportunities
    # -----------------------------------------------------------------------
    cat <<'EOF'
## RocksDB Tuning Opportunities

| Setting | Current | Recommended Range | Notes |
|---------|---------|-------------------|-------|
EOF

    # Analyze write_buffer_size
    wb_mb=$((DB_WRITE_BUF / 1048576))
    if [ "$wb_mb" -lt 32 ] 2>/dev/null; then
        echo "| write_buffer_size | ${wb_mb} MB | 32-128 MB | Current value is low for write-heavy workloads. Increasing reduces write amplification. |"
    elif [ "$wb_mb" -gt 128 ] 2>/dev/null; then
        echo "| write_buffer_size | ${wb_mb} MB | 32-128 MB | Current value is high; may consume excess memory. |"
    else
        echo "| write_buffer_size | ${wb_mb} MB | 32-128 MB | Within recommended range. |"
    fi

    # Analyze max_background_jobs
    if [ "$DB_MAX_BG_JOBS" -lt "$CPU_CORES" ] 2>/dev/null; then
        echo "| max_background_jobs | $DB_MAX_BG_JOBS | $CPU_CORES (= nproc) | Could increase to match available cores for better compaction throughput. |"
    else
        echo "| max_background_jobs | $DB_MAX_BG_JOBS | $CPU_CORES (= nproc) | Adequate for this system. |"
    fi

    # Analyze cache_size
    cache_mb=$((CKB_CACHE_SIZE / 1048576))
    mem_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo 0)
    if [ "$mem_mb" -gt 0 ] 2>/dev/null; then
        recommended=$((mem_mb / 4))
        if [ "$cache_mb" -lt "$recommended" ] 2>/dev/null; then
            echo "| cache_size (ckb.toml) | ${cache_mb} MB | ~${recommended} MB (25% of RAM) | Could increase to utilize available memory. |"
        else
            echo "| cache_size (ckb.toml) | ${cache_mb} MB | ~${recommended} MB (25% of RAM) | Reasonable for this system. |"
        fi
    fi

    # Analyze max_write_buffer_number
    if [ "$DB_MAX_WRITE_BUF_NUM" -lt 3 ] 2>/dev/null; then
        echo "| max_write_buffer_number | $DB_MAX_WRITE_BUF_NUM | 3-6 | Increasing allows more buffering during flush stalls. |"
    else
        echo "| max_write_buffer_number | $DB_MAX_WRITE_BUF_NUM | 3-6 | Within recommended range. |"
    fi

    echo ""
    echo "---"
    echo ""

    # -----------------------------------------------------------------------
    # Summary table
    # -----------------------------------------------------------------------
    echo "## Summary"
    echo ""
    echo "| Benchmark | Key Metric | Throughput | Bottleneck Hint |"
    echo "|-----------|-----------|-----------|-----------------|"

    # always_success best throughput (largest tx count, main_branch)
    best_as=""
    best_as_tp=""
    for name in "${BENCH_NAMES[@]}"; do
        if [[ "$name" == *"always_success main_branch"* ]]; then
            best_as="$name"
        fi
    done
    if [ -n "$best_as" ]; then
        txs=$(echo "$best_as" | grep -oE '[0-9]+$' || echo "?")
        tp=$(python3 -c "
mean_s = float('${BENCH_MEAN[$best_as]}') / 1e9
total = 20 * int('$txs')
print(f'{total/mean_s:,.0f} tx/s') if mean_s > 0 else print('N/A')
" 2>/dev/null || echo "N/A")
        echo "| always_success (main, ${txs} tx) | $(format_ns "${BENCH_MEAN[$best_as]}") | $tp | Block processing (no script verification) |"
    fi

    # secp best throughput
    best_secp=""
    for name in "${BENCH_NAMES[@]}"; do
        if [[ "$name" == *"secp main_branch"* ]]; then
            best_secp="$name"
        fi
    done
    if [ -n "$best_secp" ]; then
        txs=$(echo "$best_secp" | grep -oE '[0-9]+$' || echo "?")
        tp=$(python3 -c "
mean_s = float('${BENCH_MEAN[$best_secp]}') / 1e9
total = 20 * int('$txs')
print(f'{total/mean_s:,.0f} verif/s') if mean_s > 0 else print('N/A')
" 2>/dev/null || echo "N/A")
        echo "| secp_2in2out (main, ${txs} tx) | $(format_ns "${BENCH_MEAN[$best_secp]}") | $tp | Script verification (secp256k1) |"
    fi

    # resolve
    for name in "${BENCH_NAMES[@]}"; do
        if [[ "$name" == *"resolve/resolve/"* ]] && [[ "$name" != *"check_resolve"* ]]; then
            size=$(echo "$name" | grep -oE '[0-9]+$' || echo "?")
            tp=$(python3 -c "
mean_s = float('${BENCH_MEAN[$name]}') / 1e9
print(f'{1.0/mean_s:,.1f} iter/s') if mean_s > 0 else print('N/A')
" 2>/dev/null || echo "N/A")
            echo "| resolve ($size cells) | $(format_ns "${BENCH_MEAN[$name]}") | $tp | Cell resolution / UTXO lookup |"
        fi
    done

    # overall
    for name in "${BENCH_NAMES[@]}"; do
        if [[ "$name" == *"overall"* ]]; then
            size=$(echo "$name" | grep -oE '[0-9]+$' || echo "?")
            tp=$(python3 -c "
mean_s = float('${BENCH_MEAN[$name]}') / 1e9
print(f'{10.0/mean_s:,.2f} blocks/s') if mean_s > 0 else print('N/A')
" 2>/dev/null || echo "N/A")
            echo "| overall ($size tx) | $(format_ns "${BENCH_MEAN[$name]}") | $tp | Full pipeline (assembly + verification + processing) |"
        fi
    done

    echo ""
    echo "---"
    echo ""
    echo "*Report generated by run-ckb-bench.sh at $(date '+%Y-%m-%d %H:%M:%S %Z')*"

} > "$REPORT"

echo "==> Report written to: $REPORT"
echo ""
head -5 "$REPORT"
echo "..."
echo ""
echo "Full report: $REPORT"
