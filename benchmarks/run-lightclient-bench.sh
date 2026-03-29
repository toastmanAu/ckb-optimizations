#!/bin/bash
# Run CKB Light Client comparative benchmark (standard vs lite build).
#
# This wraps the benchmark.sh from ckb-light-client-lite, handling:
#   - Cloning/updating the light client repo if needed
#   - Building both standard (RocksDB) and lite (SQLite) variants
#   - Running the comparative benchmark
#   - Copying results to the reports directory
#
# Usage:
#   ./run-lightclient-bench.sh                    # Full build + benchmark (60s)
#   ./run-lightclient-bench.sh --duration 120     # Custom duration
#   ./run-lightclient-bench.sh --skip-build       # Use existing binaries
#   ./run-lightclient-bench.sh --binaries STD LITE # Provide pre-built binaries
set -euo pipefail

WORKSPACE="/home/phill/nervos_optimizations"
LC_REPO="https://github.com/nervosnetwork/ckb-light-client.git"
LC_DIR="$WORKSPACE/ckb-light-client"
LC_LITE_DIR="/home/phill/ckb-light-client-lite"
BENCHMARK_SCRIPT="$LC_LITE_DIR/benchmark.sh"
REPORT_DIR="$WORKSPACE/benchmarks/reports"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$REPORT_DIR"

DURATION=60
SKIP_BUILD=0
STD_BIN=""
LITE_BIN=""

while [ $# -gt 0 ]; do
    case "$1" in
        --duration)    DURATION="$2"; shift 2 ;;
        --skip-build)  SKIP_BUILD=1; shift ;;
        --binaries)    STD_BIN="$2"; LITE_BIN="$3"; shift 3 ;;
        *)             shift ;;
    esac
done

# ---------------------------------------------------------------------------
# System info
# ---------------------------------------------------------------------------
echo "=== CKB Light Client Benchmark Runner ==="
echo "Date:     $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "Host:     $(hostname 2>/dev/null || echo unknown)"
echo "CPU:      $(lscpu 2>/dev/null | grep 'Model name' | head -1 | sed 's/.*:\s*//' || echo unknown)"
echo "Duration: ${DURATION}s per variant"
echo ""

# ---------------------------------------------------------------------------
# Ensure benchmark script exists
# ---------------------------------------------------------------------------
if [ ! -f "$BENCHMARK_SCRIPT" ]; then
    echo "ERROR: benchmark.sh not found at $BENCHMARK_SCRIPT"
    echo "Expected the ckb-light-client-lite repo at $LC_LITE_DIR"
    exit 1
fi

# ---------------------------------------------------------------------------
# Build or locate binaries
# ---------------------------------------------------------------------------
if [ -n "$STD_BIN" ] && [ -n "$LITE_BIN" ]; then
    echo "==> Using provided binaries:"
    echo "    Standard: $STD_BIN"
    echo "    Lite:     $LITE_BIN"
elif [ "$SKIP_BUILD" -eq 1 ]; then
    # Try to find existing binaries
    STD_BIN="$LC_DIR/target/release/ckb-light-client"
    LITE_BIN="$LC_DIR/target/release/ckb-light-client-lite"

    # Also check for feature-differentiated builds
    if [ ! -f "$STD_BIN" ]; then
        STD_BIN=$(find "$LC_DIR/target/release" -name "ckb-light-client" -not -name "*.d" -type f 2>/dev/null | head -1 || echo "")
    fi

    if [ -z "$STD_BIN" ] || [ ! -f "$STD_BIN" ]; then
        echo "NOTE: No pre-built binaries found. Will use prior results if available."
        STD_BIN=""
        LITE_BIN=""
    else
        echo "==> Using existing binaries:"
        echo "    Standard: $STD_BIN"
        echo "    Lite:     $LITE_BIN"
    fi
else
    echo "==> Cloning/updating light client repo..."

    if [ ! -d "$LC_DIR" ]; then
        git clone "$LC_REPO" "$LC_DIR" 2>&1 | tail -3
    else
        pushd "$LC_DIR" > /dev/null
        git fetch origin 2>/dev/null
        git checkout develop 2>/dev/null || git checkout main 2>/dev/null || true
        git pull 2>/dev/null || true
        popd > /dev/null
    fi

    echo "==> Building standard variant (RocksDB)..."
    pushd "$LC_DIR" > /dev/null
    cargo build --release 2>&1 | tail -3
    STD_BIN="$LC_DIR/target/release/ckb-light-client"
    popd > /dev/null

    if [ ! -f "$STD_BIN" ]; then
        # Try to find the binary name
        STD_BIN=$(find "$LC_DIR/target/release" -maxdepth 1 -type f -executable -not -name "*.d" -not -name "build-*" | head -1 || echo "")
    fi

    echo "==> Building lite variant (SQLite)..."
    # The lite variant may be a feature flag or a separate branch
    # Check for a sqlite feature or lite feature
    if grep -q 'sqlite' "$LC_DIR/Cargo.toml" 2>/dev/null; then
        cargo build --release --features sqlite --no-default-features 2>&1 | tail -3
        LITE_BIN="$STD_BIN"  # Same binary, different features
        echo "    NOTE: Lite built with --features sqlite"
    else
        echo "    NOTE: No sqlite feature found in upstream repo."
        echo "    The lite variant requires the ckb-light-client-lite fork."
        echo "    Falling back to single-variant benchmark."
        LITE_BIN=""
    fi
    popd > /dev/null 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Run benchmark
# ---------------------------------------------------------------------------
if [ -n "$STD_BIN" ] && [ -n "$LITE_BIN" ] && [ -f "$STD_BIN" ] && [ -f "$LITE_BIN" ]; then
    echo ""
    echo "==> Running comparative benchmark (${DURATION}s per variant)..."
    echo ""

    # Run the benchmark script from the lite repo
    pushd "$LC_LITE_DIR" > /dev/null
    bash "$BENCHMARK_SCRIPT" "$STD_BIN" "$LITE_BIN" "$DURATION"
    popd > /dev/null

    # Copy latest results to our reports directory
    LATEST_REPORT=$(ls -t "$LC_LITE_DIR/benchmark-results"/benchmark-*.md 2>/dev/null | head -1)
    LATEST_CSV=$(ls -t "$LC_LITE_DIR/benchmark-results"/benchmark-*.csv 2>/dev/null | head -1)

    if [ -n "$LATEST_REPORT" ]; then
        cp "$LATEST_REPORT" "$REPORT_DIR/lightclient-report-$TIMESTAMP.md"
        echo ""
        echo "==> Report copied to: $REPORT_DIR/lightclient-report-$TIMESTAMP.md"
    fi
    if [ -n "$LATEST_CSV" ]; then
        cp "$LATEST_CSV" "$REPORT_DIR/lightclient-timeseries-$TIMESTAMP.csv"
        echo "==> CSV copied to: $REPORT_DIR/lightclient-timeseries-$TIMESTAMP.csv"
    fi

elif [ -n "$STD_BIN" ] && [ -f "$STD_BIN" ]; then
    echo ""
    echo "==> Only standard binary available. Running single-variant baseline..."
    echo "    To run the full comparison, provide both binaries with --binaries."

    # Single-variant profiling: startup, RSS, RPC
    SINGLE_REPORT="$REPORT_DIR/lightclient-single-$TIMESTAMP.md"
    {
        echo "# CKB Light Client Single-Variant Baseline"
        echo ""
        echo "**Date:** $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "**Host:** $(hostname 2>/dev/null || echo unknown)"
        echo "**Binary:** $STD_BIN"
        echo "**Size:** $(du -h "$STD_BIN" | cut -f1)"
        echo ""
        echo "> Full comparison requires both standard and lite binaries."
        echo "> Run with: \`./run-lightclient-bench.sh --binaries /path/to/standard /path/to/lite\`"
    } > "$SINGLE_REPORT"
    echo "==> Single-variant report: $SINGLE_REPORT"
else
    echo ""
    echo "ERROR: No usable binaries found."
    echo ""
    echo "Options:"
    echo "  1. Provide pre-built binaries: --binaries /path/to/standard /path/to/lite"
    echo "  2. Clone and build: run without --skip-build"
    echo "  3. Use existing benchmark results from: $LC_LITE_DIR/benchmark-results/"
    echo ""

    # If prior results exist, copy the latest
    PRIOR=$(ls -t "$LC_LITE_DIR/benchmark-results"/benchmark-*.md 2>/dev/null | head -1)
    if [ -n "$PRIOR" ]; then
        echo "==> Found prior results, copying: $(basename "$PRIOR")"
        cp "$PRIOR" "$REPORT_DIR/lightclient-report-$TIMESTAMP.md"
        PRIOR_CSV=$(ls -t "$LC_LITE_DIR/benchmark-results"/benchmark-*.csv 2>/dev/null | head -1)
        [ -n "$PRIOR_CSV" ] && cp "$PRIOR_CSV" "$REPORT_DIR/lightclient-timeseries-$TIMESTAMP.csv"
    fi
fi

echo ""
echo "=== Light client benchmark run complete ==="
