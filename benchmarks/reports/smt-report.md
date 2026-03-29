# Sparse Merkle Tree Performance Benchmark Report

**Date:** 2026-03-29T04:25:47Z
**Host:** driveThree -- x86_64
**CPU:** Intel(R) Core(TM) i7-14700KF
**Rust:** rustc 1.92.0 (ded5c06cf 2025-12-08)
**SMT Version:** 0.6.2
**Hash Backend:** blake2b-rs

## 1. Tree Operations Scaling

| Tree Size | Update (single) | Update All (batch) | Get (single) | Ops/sec (update) | Ops/sec (get) |
|-----------|-----------------|-------------------|--------------|------------------|---------------|
|       100 |        44.35 us |          42.48 us |        28 ns |         22.55K/s |      35.71M/s |
|      1000 |        71.03 us |          68.26 us |        27 ns |         14.08K/s |      37.04M/s |
|     10000 |        67.62 us |          66.65 us |        26 ns |         14.79K/s |      38.46M/s |
|     50000 |        65.66 us |          66.43 us |        26 ns |         15.23K/s |      38.46M/s |
|    100000 |        72.55 us |          74.52 us |        27 ns |         13.78K/s |      37.04M/s |

## 2. Proof Generation & Verification

| Tree Size | Leaves | Gen Time | Verify Time | Proof Size | Verify/sec |
|-----------|--------|----------|-------------|------------|------------|
|       100 |      1 |  9.61 us |     7.07 us |      256 B |  141.36K/s |
|       100 |      5 | 47.78 us |    31.48 us |      768 B |   31.77K/s |
|       100 |     10 | 93.57 us |    60.16 us |   1.28 KiB |   16.62K/s |
|       100 |     20 | 188.17 us |   117.77 us |   1.94 KiB |    8.49K/s |
|       100 |     40 | 458.91 us |   196.27 us |   2.41 KiB |    5.10K/s |
|      1000 |      1 | 10.07 us |     7.37 us |      320 B |  135.74K/s |
|      1000 |      5 | 51.42 us |    35.29 us |   1.31 KiB |   28.34K/s |
|      1000 |     10 | 109.46 us |    70.40 us |   2.38 KiB |   14.20K/s |
|      1000 |     20 | 250.73 us |   128.93 us |   4.03 KiB |    7.76K/s |
|      1000 |     40 | 611.22 us |   255.91 us |   6.47 KiB |    3.91K/s |
|     10000 |      1 | 10.22 us |     7.82 us |      448 B |  127.93K/s |
|     10000 |      5 | 56.34 us |    38.66 us |   1.81 KiB |   25.87K/s |
|     10000 |     10 | 120.14 us |    79.06 us |   3.38 KiB |   12.65K/s |
|     10000 |     20 | 371.76 us |   107.22 us |   5.97 KiB |    9.33K/s |
|     10000 |     40 | 784.06 us |   249.61 us |  10.38 KiB |    4.01K/s |
|    100000 |      1 | 10.50 us |     9.01 us |      576 B |  110.95K/s |
|    100000 |      5 | 65.26 us |    42.05 us |   2.38 KiB |   23.78K/s |
|    100000 |     10 | 134.22 us |    83.71 us |   4.47 KiB |   11.95K/s |
|    100000 |     20 | 418.65 us |   128.19 us |   8.03 KiB |    7.80K/s |
|    100000 |     40 | 831.04 us |   314.02 us |  14.69 KiB |    3.18K/s |

## 3. Store Operation Profile

Store operation counts when inserting N keys via `update()` into an empty tree.

| Operation | Tree 100 | Tree 1000 | Tree 10000 | Tree 100000 | 
|-----------|----------|----------|----------|----------|
|    branch_get |    25601 |   256001 |  2560001 | 25600001 | 
| branch_insert |    25600 |   256000 |  2560000 | 25600000 | 
| branch_remove |        0 |        0 |        0 |        0 | 
|      leaf_get |        0 |        0 |        0 |        0 | 
|   leaf_insert |      100 |     1000 |    10000 |   100000 | 
|   leaf_remove |        0 |        0 |        0 |        0 | 

Store operation counts for a single `get()` on a tree of size N.

| Operation | Tree 100 | Tree 1000 | Tree 10000 | Tree 100000 | 
|-----------|----------|----------|----------|----------|
|    branch_get |        0 |        0 |        0 |        0 | 
| branch_insert |        0 |        0 |        0 |        0 | 
| branch_remove |        0 |        0 |        0 |        0 | 
|      leaf_get |        1 |        1 |        1 |        1 | 
|   leaf_insert |        0 |        0 |        0 |        0 | 
|   leaf_remove |        0 |        0 |        0 |        0 | 

## 4. Throughput Summary

| Metric | Value | Notes |
|--------|-------|-------|
| Peak batch update throughput | 38.71K/s | batch size 100 |
| Proof verify throughput (20 leaves, 10K tree) | 2024.28/s | gen+verify combined |
| Single update on 50K tree | 23634.35/s | incremental insert |

## Comparison Baseline

Reference: Quake's C SMT optimization (ckb_smt.h), 36 experiments tracked via commits.

| Key/Value Pairs in Tree | Leaves Verified | Cycles (before) | Cycles (after) | Reduction |
|---|---|---|---|---|
| 16 | 1 | 116 K | 116 K | baseline |
| 131,072 | 40 | 6,919 K | 1,703 K | 75.4% |

Hot paths targeted: `smt_calculate_root()` and `_smt_merge()` in `c/ckb_smt.h`.
The Rust SMT timings above can be cross-referenced with these cycle counts
when evaluating optimization impact on the same algorithmic operations.
