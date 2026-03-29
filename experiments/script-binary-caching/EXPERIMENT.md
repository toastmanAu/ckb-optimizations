# Experiment: Script Binary Caching

**Component:** CKB Node (`ckb/script/src/types.rs`, `ckb/script/src/verify.rs`)
**Branch:** `optimization/script-verification-caching`
**Started:** 2026-03-29
**Status:** In progress

## Hypothesis

CKB creates a new `TxData` per transaction, which rebuilds the `binaries_by_data_hash` HashMap
and creates new `LazyData` wrappers each time. When processing a block with many transactions
that use the same scripts (e.g., the secp256k1 lock script), the same script binary is:

1. Looked up from RocksDB (via `load_cell_data_hash`) once per cell_dep per transaction
2. Loaded from RocksDB (via `get_cell_data`) once per unique script per transaction

For a block with 100 transactions all using the same lock script, that's 100 redundant
`load_cell_data_hash` calls and 100 redundant `get_cell_data` calls for the same data.

Adding a cross-transaction binary cache keyed by `code_hash` should eliminate this redundancy.

## Current Architecture

### Per-Transaction Flow (types.rs TxData::new())

```
For each tx in block:
  TxData::new():
    1. For each cell_dep:
       - data_loader.load_cell_data_hash(cell_meta)  ← RocksDB read (or store cache hit)
       - LazyData::from_cell_meta()                   ← Creates new lazy wrapper
       - Insert into binaries_by_data_hash HashMap
    2. Build lock_groups and type_groups from inputs/outputs
    3. Build outputs CellMeta list

  For each script_group:
    - extract_script() → LazyData.access() → get_cell_data()  ← RocksDB read (first time)
    - create_scheduler() → SgData::new()
    - run VM
```

### What's Already Cached

- `LazyData` caches the binary after first load — **but per-TxData instance**
- `CellMeta.mem_cell_data` may hold data if already in memory
- `StoreCache` at the DB layer has `cell_data_cache_size = 128` entries (tiny)
- `load_cell_data_hash` may hit `StoreCache.cell_data_hash` (128 entries)

### What's NOT Cached

- **Script binaries across transactions**: Each TxData creates fresh LazyData instances
- **load_cell_data_hash results**: Called for every cell_dep of every tx (may hit DB cache)
- **Dep group expansion**: Dep groups are re-expanded per transaction

## Optimization Design

### Option A: Shared LazyData Cache (Low Risk)

Pass a shared `Arc<HashMap<Byte32, LazyData>>` into TxData::new(), pre-populated with
LazyData instances from previous transactions in the same block. Since LazyData uses
Arc<RwLock<DataGuard>>, sharing the same LazyData means a binary loaded for tx[0]
is immediately available to tx[1] without any RocksDB hit.

**Pros:** Minimal code change, leverages existing LazyData caching
**Cons:** Requires threading the shared cache through the verification pipeline

### Option B: Pre-loaded Binary Cache (Medium Risk)

Before verifying a block, scan all transactions to identify unique cell_deps,
pre-load their binaries, and pass the pre-loaded cache into each TxData.

**Pros:** Eliminates lazy loading overhead entirely, predictable memory usage
**Cons:** Front-loads all IO; some scripts might not be needed if verification fails early

### Option C: Application-Level LRU on data_loader (Low Risk)

Add an LRU cache wrapping the data_loader's `get_cell_data` method. This is
less targeted but catches all data loads, not just script binaries.

**Pros:** Simple, catches broader patterns
**Cons:** Less precise, may evict useful entries

### Chosen Approach: Option A (Shared LazyData)

Lowest risk, most targeted, and the architecture already supports it since
LazyData clones share the Arc interior.

## Implementation Plan

1. Add `script_binary_cache: Arc<Mutex<HashMap<Byte32, LazyData>>>` parameter to
   `TransactionScriptsVerifier::new()` (or a new `new_with_cache()` variant)

2. In `TxData::new()`, check the cache before creating a new LazyData. If a matching
   `data_hash` entry exists, reuse it. Otherwise create and insert.

3. At the block verification level, create one shared cache and pass it to each
   transaction's verifier.

4. The cache lives for the duration of one block verification, then is dropped.

## Changes Required

### types.rs
- Modify `TxData::new()` to accept optional `&ScriptBinaryCache`
- In the cell_dep loop, check cache before creating LazyData
- After creating LazyData, insert into cache

### verify.rs
- Add `ScriptBinaryCache` type alias
- Add `new_with_cache()` constructor that forwards to TxData

### Caller (verification/block verification)
- Create shared cache before block verification loop
- Pass to each transaction's verifier

## Risks

- **Memory**: Cache holds Bytes for all unique script binaries in a block. Typical blocks
  use 2-5 unique scripts, so this is a few MB at most.
- **Correctness**: LazyData is already Arc-based and thread-safe. Sharing across transactions
  within the same block is safe because cell_deps are resolved identically.
- **Reorg safety**: Cache is block-scoped, dropped after each block. No stale data risk.

## Results Log

| Date | Benchmark | Metric | Baseline | Optimized | Delta | Notes |
|------|-----------|--------|----------|-----------|-------|-------|
| | | | | | | |

*Results to be filled after benchmark runs.*
