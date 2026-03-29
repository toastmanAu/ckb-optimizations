# Experiments

Each subdirectory is a self-contained optimization experiment with:

- `EXPERIMENT.md` — hypothesis, analysis, config changes, and **results log**
- Config files or patches for the change
- `run-comparison.sh` — script to reproduce the A/B benchmark
- Any supporting data (flamegraphs, profiles, etc.)

## Rules

1. **Every experiment gets an EXPERIMENT.md** before any code changes
2. **Record the baseline** in the results log before the optimized run
3. **One variable at a time** — don't combine experiments unless explicitly testing interaction
4. **Record ALL results**, including failures and regressions — negative results are data
5. **Include system info** with every result (host, CPU, RAM, Rust version)
6. **Link to the commit** that introduced the change
7. **Update status** when done (success/failure/inconclusive/abandoned)

## Experiment Index

| Experiment | Component | Status | Branch | Summary |
|-----------|-----------|--------|--------|---------|
| [rocksdb-tuning](rocksdb-tuning/) | CKB node | In progress | `optimization/rocksdb-cache-tuning` | Write buffer, cache, and background job tuning |
