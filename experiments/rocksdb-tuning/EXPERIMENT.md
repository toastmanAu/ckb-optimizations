# Experiment: RocksDB Configuration Tuning

**Component:** CKB Node (`ckb/resource/default.db-options` + `ckb/resource/ckb.toml`)
**Branch:** `optimization/rocksdb-cache-tuning`
**Started:** 2026-03-29
**Status:** In progress

## Hypothesis

CKB's default RocksDB configuration is conservative and generic. Tuning write buffers,
background jobs, cache sizes, and per-column-family settings for CKB's specific access
patterns should reduce IO amplification and improve block processing throughput.

## Baseline Configuration

### default.db-options
```ini
[DBOptions]
bytes_per_sync=1048576          # 1MB
max_background_jobs=6
max_total_wal_size=134217728    # 128MB

[CFOptions "default"]
level_compaction_dynamic_level_bytes=true
write_buffer_size=8388608       # 8MB — small
min_write_buffer_number_to_merge=1
max_write_buffer_number=2       # minimal
```

### ckb.toml [db] section
```toml
cache_size = 268435456          # 256MB HyperClockCache

[store]
header_cache_size          = 4096
cell_data_cache_size       = 128   # very small
block_proposals_cache_size = 30
block_tx_hashes_cache_size = 30
block_uncles_cache_size    = 30
```

### Code-level settings (hardcoded in db.rs)
- HyperClockCache with 4096 byte entry charge
- Ribbon filter at 10.0 bits/key (good)
- TwoLevelIndexSearch (good)
- Partition filters enabled (good)
- Pin L0 index/filter in cache (good)
- COLUMN_BLOCK_BODY: 32-byte prefix extractor (good)

## Analysis

### CKB's 19 Column Families and Access Patterns

| Column | Name | Pattern | Hot? | Notes |
|--------|------|---------|------|-------|
| 0 | Index | Point lookup + range | Med | Block number ↔ hash |
| 1 | Headers | Point lookup (cached 4096) | **High** | Read-heavy during validation |
| 2 | Block body | Prefix scan + range write | **High** | 32-byte prefix extractor, tx data |
| 3 | Uncles | Point lookup | Low | Rarely accessed |
| 4 | Meta | Point lookup | Med | Tip, epoch (small) |
| 5 | Tx info | Point lookup + write | Med | tx location lookups |
| 6 | Block ext | Point lookup | Low | Block metadata |
| 7 | Proposals | Point lookup (cached 128) | Low-Med | |
| 8 | Block epoch | Point lookup | Low | |
| 9 | Epochs | Point lookup | Low | Append-mostly |
| 10 | Cells | Point lookup + write | **High** | Live UTXO set — hottest write path |
| 11 | Uncle index | Point lookup | Low | |
| 12 | Cell data | Point lookup (cached 128) | **High** | Variable size, frequently read |
| 13 | Number-hash | Point lookup | Low | |
| 14 | Cell data hash | Point lookup (cached 128) | Med | |
| 15 | Block extension | Point lookup | Low | Optional |
| 16 | MMR | Append-only | Low | Chain root |
| 17 | Block filter | Append | Low | SPV filters |
| 18 | Filter hash | Append | Low | SPV filter hashes |

### Key bottlenecks identified

1. **Write buffer too small (8MB)**: CKB writes entire blocks atomically. A block with many
   transactions can easily exceed 8MB. Small buffers → frequent L0 flushes → high write
   amplification → compaction pressure.

2. **Only 2 write buffers**: When one is being flushed, only one remains for writes.
   Under load this causes write stalls. Should be 3-6.

3. **Cache too small for available RAM**: 256MB on a 62GB machine. RocksDB recommends
   dedicating significant memory to block cache for read-heavy workloads.

4. **Application-level cell_data_cache is tiny (128 entries)**: Cell data is the most
   frequently accessed data during verification. 128 entries is basically nothing.

5. **Same config for all column families**: Headers (read-heavy, small entries) and
   block body (write-heavy, large entries) have very different optimal configs.

6. **Background jobs (6)** are low for 28 cores: compaction and flush compete.

## Experiments

### Experiment 1: Optimized db-options + cache tuning

**Changes:**
- write_buffer_size: 8MB → 64MB (8x, reduces flush frequency)
- max_write_buffer_number: 2 → 4 (absorb flush stalls)
- min_write_buffer_number_to_merge: 1 → 2 (reduce write amplification)
- max_background_jobs: 6 → 12 (better utilization of 28 cores)
- bytes_per_sync: 1MB → 2MB (reduce sync overhead)
- max_total_wal_size: 128MB → 512MB (allow more buffered writes)
- cache_size: 256MB → 2GB (utilize available RAM)
- cell_data_cache_size: 128 → 4096 (32x for hot UTXO data)
- header_cache_size: 4096 → 8192 (2x)
- block_tx_hashes_cache_size: 30 → 256

**Expected impact:**
- Reduced write amplification → lower CPU/IO for compaction
- Fewer flush stalls → more consistent block processing latency
- Higher cache hit rate → fewer disk reads during verification

**Risks:**
- Higher memory usage (~2.5GB vs ~500MB)
- Larger WAL → slower recovery on crash (acceptable for optimization testing)

### Experiment 2: Per-column-family tuning (future)

Separate configs for:
- Columns 1,10,12 (hot read/write): larger buffers, bloom/ribbon filters
- Columns 2 (block body): optimized for prefix scan + large values
- Columns 9,16,17,18 (append-only): minimal write buffers, sequential optimization

---

## Results Log

| Date | Experiment | Benchmark | Metric | Baseline | Optimized | Delta | Notes |
|------|-----------|-----------|--------|----------|-----------|-------|-------|
| | | | | | | | |

*Results to be filled after benchmark runs.*
