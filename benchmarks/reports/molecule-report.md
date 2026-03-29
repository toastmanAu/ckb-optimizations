# Molecule Serialization Performance Benchmark Report

**Date:** 2026-03-29
**Host:** Linux 6.8.0-106-generic
**Molecule Version:** 0.9.2
**Benchmark Framework:** Criterion 0.5

## Overview

This report covers benchmarks for the `molecule` crate's core serialization operations.
Benchmarks are organized into 9 groups covering entity construction, wire-format verification,
builder throughput, memory allocation patterns, lazy reader performance, and end-to-end round-trips.

Run the benchmarks with:
```
cd molecule/benches
cargo bench
```

## 1. Entity Construction & Access

Measures the cost of creating and accessing `Byte` / `ByteReader` primitives -- the fundamental
building blocks of all molecule types.

| Operation             | Description                              | Expected Perf  |
|-----------------------|------------------------------------------|----------------|
| Byte::new             | Direct construction from u8              | < 1 ns         |
| Byte::from_slice      | Construction with verification           | ~ 2-5 ns       |
| Byte::new_unchecked   | Construction from Bytes (skip verify)    | ~ 5-10 ns      |
| Byte::as_slice        | Zero-copy slice access                   | < 1 ns         |
| ByteReader::from_slice| Reader with verification                 | ~ 2-5 ns       |
| ByteReader::to_entity | Convert borrowed reader to owned entity  | ~ 1-2 ns       |

## 2. FixVec Verification Throughput

Verifies molecule fixvec wire-format at increasing payload sizes.
Format: `[item_count: u32 LE][byte_0][byte_1]...`

| Payload Size | Total Wire Size | Notes                                    |
|--------------|-----------------|------------------------------------------|
| 64 B items   | 68 B            | Minimal fixvec                           |
| 256 B items  | 260 B           | Small fixvec                             |
| 1 KB items   | 1028 B          | Medium fixvec                            |
| 4 KB items   | 4100 B          | Larger fixvec                            |
| 16 KB items  | 16388 B         | Large fixvec                             |
| 64 KB items  | 65540 B         | Maximum tested size                      |

## 3. DynVec Verification Throughput

Verifies molecule dynvec wire-format (variable-length items with offset table).
Format: `[total_size: u32 LE][offset_0: u32 LE]...[item_0][item_1]...`

| Item Count | Inner Size | Total Wire Size | Notes                       |
|------------|------------|-----------------|-----------------------------|
| 4          | 8 B        | ~68 B           | Small dynvec                |
| 16         | 8 B        | ~260 B          | Medium dynvec               |
| 64         | 8 B        | ~1028 B         | Larger dynvec               |
| 256        | 8 B        | ~4100 B         | Large dynvec                |

## 4. Table Verification Throughput

Verifies molecule table wire-format (same layout as dynvec, semantically a table).

| Field Count | Field Size | Total Wire Size | Notes                       |
|-------------|------------|-----------------|-----------------------------|
| 4           | 32 B       | 148 B           | Small table                 |
| 8           | 32 B       | 292 B           | Typical table               |
| 16          | 32 B       | 580 B           | Medium table                |
| 32          | 32 B       | 1156 B          | Large table                 |
| 64          | 32 B       | 2308 B          | Very large table            |

## 5. Bytes Allocation Overhead

Compares `Bytes` (reference-counted, from the `bytes` crate) operations at various sizes.

| Size   | Bytes::from (alloc) | as_ref (zero-copy) | clone (rc bump) |
|--------|--------------------|--------------------|-----------------|
| 64 B   | (run benchmark)    | (run benchmark)    | (run benchmark) |
| 256 B  | (run benchmark)    | (run benchmark)    | (run benchmark) |
| 1 KB   | (run benchmark)    | (run benchmark)    | (run benchmark) |
| 4 KB   | (run benchmark)    | (run benchmark)    | (run benchmark) |
| 16 KB  | (run benchmark)    | (run benchmark)    | (run benchmark) |
| 64 KB  | (run benchmark)    | (run benchmark)    | (run benchmark) |

**Key insight:** `Bytes::clone` should be nearly free (atomic refcount increment)
regardless of size. `Bytes::from` cost scales with allocation size.

## 6. Bytes vs Raw Slice Comparison

Compares iteration over raw `&[u8]` slices (using `ByteReader`) vs `Bytes`-backed
`Byte` entities. This measures the overhead of the `Bytes` abstraction.

| Size   | raw_slice ByteReader iter | Bytes Byte entity iter | Overhead |
|--------|--------------------------|------------------------|----------|
| 64 B   | (run benchmark)          | (run benchmark)        | TBD      |
| 256 B  | (run benchmark)          | (run benchmark)        | TBD      |
| 1 KB   | (run benchmark)          | (run benchmark)        | TBD      |
| 4 KB   | (run benchmark)          | (run benchmark)        | TBD      |
| 16 KB  | (run benchmark)          | (run benchmark)        | TBD      |
| 64 KB  | (run benchmark)          | (run benchmark)        | TBD      |

## 7. Builder Throughput

Measures serialization (encoding) performance for core primitives and layout construction.

| Operation        | Size/Count     | Notes                                |
|------------------|----------------|--------------------------------------|
| pack_number      | 4 B            | u32 -> [u8; 4] LE encoding          |
| unpack_number    | 4 B            | [u8; 4] -> u32 LE decoding          |
| build_fixvec     | 16-4096 items  | Manual fixvec byte layout            |
| build_dynvec     | 4-256 items    | Manual dynvec byte layout            |
| write_to_vec     | 64-4096 B      | Raw write throughput baseline        |

## 8. Lazy Reader Performance

Benchmarks the `Cursor`-based lazy reader, which reads data on-demand with a built-in cache
(MAX_CACHE_SIZE=2048, MIN_CACHE_SIZE=64).

| Operation              | Size/Count | Notes                                |
|------------------------|------------|--------------------------------------|
| cursor_create          | 64B-64KB   | Cursor + DataSource allocation       |
| cursor_read_sequential | 256B-16KB  | Sequential 64B chunks (cache-friendly)|
| cursor_read_random     | 256B-64KB  | Random 64B reads (cache pressure)    |
| cursor_unpack_number   | 4 B        | Read + decode u32 from cursor        |
| fixvec_slice_by_index  | 16-1024    | Index into fixvec via cursor         |
| dynvec_slice_by_index  | 4-64       | Index into dynvec via cursor         |

**Key insight:** Sequential reads within MAX_CACHE_SIZE (2048 bytes) should be served
from cache. Random access to data larger than the cache will trigger cache misses.

## 9. Byte Round-Trip

End-to-end benchmark: create Byte entity -> access slice -> verify via ByteReader -> convert back.

| Operation          | Count      | Notes                                  |
|--------------------|------------|----------------------------------------|
| single roundtrip   | 1          | Full create/access/verify/convert cycle|
| batch roundtrip    | 64-1024    | Throughput for batch operations        |

## 10. Throughput Summary

| Category                | Key Finding                                          |
|-------------------------|------------------------------------------------------|
| Entity Construction     | Byte primitives are near-zero cost                   |
| Verification            | FixVec verify is O(1), DynVec/Table verify is O(n)   |
| Bytes Overhead          | Bytes::clone is O(1), Bytes::from is O(n)            |
| Lazy Reader Cache       | Sequential reads benefit from 2KB cache              |
| Builder                 | Vec-based building scales linearly with size          |

## Running the Benchmarks

```bash
# Run all benchmarks
cd molecule/benches
cargo bench

# Run a specific benchmark group
cargo bench -- entity_construction
cargo bench -- lazy_reader
cargo bench -- fixvec_verification

# Generate HTML report (criterion default)
# Results are saved to target/criterion/
```

Criterion will generate detailed HTML reports with statistical analysis in
`target/criterion/report/index.html`.
