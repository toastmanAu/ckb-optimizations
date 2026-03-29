# Nervos Optimization Experiments — Progress Log

## Project Overview

Long-term optimization work across the Nervos CKB ecosystem, guided by the deep research report (`deep-research-report.md`). Focus areas: CKB-VM execution, SMT proof verification, Molecule serialization, CKB node storage/verification, and light client portability.

### Reference Work
- **Quake's SMT optimization**: 36 iterative experiments on `sparse-merkle-tree` C verifier (`c/ckb_smt.h`), reducing proof verification from 6,994K → 1,703K cycles (75.7% improvement). Methodology: targeted micro-optimizations on blake2b hashing and memory operations, tracked via "context:" commits on the `bench-optimize` branch.
- **CKB Light Client Lite benchmarks**: Comparative benchmark of standard (RocksDB/glibc) vs lite (SQLite/musl) builds. Lite wins on every metric: -18% binary size, -18% RSS, -98% disk usage, identical startup/RPC. Script at `/home/phill/ckb-light-client-lite/benchmark.sh`, results at `/home/phill/ckb-light-client-lite/benchmark-results/`.

### Repos in Workspace

| Repo | Optimization Branches | Focus |
|------|----------------------|-------|
| `ckb` | `optimization/rocksdb-cache-tuning`, `optimization/script-verification-caching`, `optimization/parallel-script-groups` | Node-side throughput |
| `ckb-vm` | `optimization/dispatch-and-asm-tuning`, `optimization/memory-backend-heuristics` | VM execution speed |
| `sparse-merkle-tree` | `optimization/hash-memcpy-microopt` | On-chain cycle reduction |
| `molecule` | `optimization/zero-copy-alloc-reduction` | Serialization performance |
| `ckb-standalone-debugger` | `optimization/profiling-harness-baseline` | Tooling/profiling |

---

## Log

### 2026-03-29 — Session 1: Setup & Benchmark Infrastructure

**Done:**
- Cloned all 5 repos into workspace
- Created dedicated optimization branches per focus area
- Explored existing benchmark infrastructure across all repos
- Identified key entry points from deep research report

**Existing benchmark infrastructure found:**
- `ckb`: Criterion 0.5 benchmarks (always_success, secp_2in2out, overall, resolve), Prometheus metrics, RocksDB options file
- `ckb-vm`: Minimal (bits_benchmark only), but has runner example and cost_model module
- `sparse-merkle-tree`: Criterion 0.2 benchmarks (smt_benchmark, store_counter), nostd-runner with cycle counting via ckb-debugger
- `molecule`: None — no benchmarks exist at all
- `ckb-standalone-debugger`: No structured benchmarks, but has flamegraph, pprof, coverage, and step-logging built in

**Built (session 1, not yet compiled/verified):**
- `benchmarks/run-ckb-bench.sh` — CKB node benchmark runner (parses Criterion JSON, generates markdown with RocksDB tuning analysis)
- `benchmarks/run-ckb-bench-quick.sh` — CI-mode wrapper (smaller tx counts)
- `benchmarks/reports/molecule-report.md` — Benchmark design doc (what to measure)
- `molecule/benches/` — New Criterion 0.5 benchmark suite (entity construction, fixvec/dynvec/table verification, bytes alloc, lazy reader, round-trips)
- `ckb-vm/benches/vm_benchmark.rs` — Execution mode + memory backend + cost model consistency benchmarks with markdown report gen
- `sparse-merkle-tree/benches/comprehensive_benchmark.rs` — Tree ops scaling, proof gen/verify, store profiling, throughput summary with markdown report gen

---

### 2026-03-29 — Session 2: Fix Compilation, Runner Scripts, Orchestration

**Done:**
- Fixed SMT comprehensive_benchmark.rs compilation errors (Criterion 0.2 `'static` closure issues — split loop into per-leaf-count functions with `move` closures)
- Created runner scripts for all repos:
  - `benchmarks/run-vm-bench.sh` — CKB-VM Criterion + report generation
  - `benchmarks/run-smt-bench.sh` — SMT comprehensive + original benchmarks, optional nostd-runner cycle counting
  - `benchmarks/run-molecule-bench.sh` — Molecule Criterion + auto-parsed markdown report
  - `benchmarks/run-debugger-bench.sh` — Debugger profiling mode overhead measurement (fast/full/flamegraph/coverage/steplog)
  - `benchmarks/run-all.sh` — Master orchestration (runs all suites, generates combined summary)
- Verified compilation: molecule (Criterion 0.5), ckb-vm, smt all compile successfully
- Debugger build requires `protoc` system dependency (`sudo apt install protobuf-compiler`)

**Benchmark infrastructure status:**

| Repo | Benchmark Code | Runner Script | Compiles? |
|------|---------------|---------------|-----------|
| ckb | Existing Criterion benches | `run-ckb-bench.sh` | Pending (long build) |
| ckb-vm | `vm_benchmark.rs` (new) | `run-vm-bench.sh` | Yes |
| sparse-merkle-tree | `comprehensive_benchmark.rs` (new) | `run-smt-bench.sh` | Yes |
| molecule | `molecule_benchmark.rs` (new) | `run-molecule-bench.sh` | Yes |
| ckb-standalone-debugger | Shell-based profiling harness | `run-debugger-bench.sh` | Needs protoc |

**Next steps:**
- Install protoc and verify debugger build
- Run baseline benchmarks on all repos (`./benchmarks/run-all.sh`)
- Begin optimization experiments guided by baseline results and deep research report priorities

---
