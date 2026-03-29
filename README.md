# CKB Optimizations

Performance optimization experiments across the Nervos CKB ecosystem.

## Structure

```
benchmarks/           # Runner scripts and reports
├── run-all.sh        # Master orchestration (runs everything)
├── run-ckb-bench.sh  # CKB node (block processing, secp verification, RocksDB)
├── run-vm-bench.sh   # CKB-VM (execution modes, memory backends)
├── run-smt-bench.sh  # Sparse Merkle Tree (ops scaling, proof gen/verify)
├── run-molecule-bench.sh     # Molecule serialization
├── run-debugger-bench.sh     # Debugger profiling mode overhead
├── run-lightclient-bench.sh  # Light client standard vs lite
└── reports/          # Generated baseline and comparison reports

ckb/                  # submodule: CKB full node
ckb-vm/               # submodule: CKB-VM (RISC-V virtual machine)
sparse-merkle-tree/   # submodule: SMT library
molecule/             # submodule: Molecule serialization
ckb-standalone-debugger/  # submodule: Debugger + profiling tools
```

## Optimization Branches

Each submodule has dedicated optimization branches:

| Repo | Branch | Focus |
|------|--------|-------|
| ckb | `optimization/rocksdb-cache-tuning` | DB cache/compaction tuning |
| ckb | `optimization/script-verification-caching` | Script extraction memoization |
| ckb | `optimization/parallel-script-groups` | Parallel group verification |
| ckb-vm | `optimization/dispatch-and-asm-tuning` | VM dispatch improvements |
| ckb-vm | `optimization/memory-backend-heuristics` | Memory backend selection |
| sparse-merkle-tree | `optimization/hash-memcpy-microopt` | Blake2b + memory micro-opts |
| molecule | `optimization/zero-copy-alloc-reduction` | Allocation reduction |
| ckb-standalone-debugger | `optimization/profiling-harness-baseline` | Profiling tooling |

## Quick Start

```bash
# Clone with submodules
git clone --recurse-submodules https://github.com/toastmanAu/ckb-optimizations.git
cd ckb-optimizations

# Run quick baseline (CI-sized inputs)
./benchmarks/run-all.sh --quick

# Run full benchmarks
./benchmarks/run-all.sh

# Run individual suites
./benchmarks/run-vm-bench.sh
./benchmarks/run-smt-bench.sh
./benchmarks/run-molecule-bench.sh
```

## Reports

Benchmark reports are generated as markdown in `benchmarks/reports/`. Each report captures system info, raw measurements, and analysis.

See [PROGRESS.md](PROGRESS.md) for the running log of optimization attempts and results.

## Methodology

Guided by the [deep research report](deep-research-report.md) which identifies optimization opportunities across the ecosystem. Approach:

1. **Measure first** — establish baselines before changing anything
2. **Targeted experiments** — one variable at a time on dedicated branches
3. **Evidence-based** — every change validated against benchmarks
4. **Iterative** — small improvements compound (see Quake's SMT work: 36 experiments, 75.7% cycle reduction)
