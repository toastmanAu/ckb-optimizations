# CKB-VM Performance Benchmark Report

**Date:** 2026-03-29T15:25:18.323141754+10:30
**Host:** driveThree -- x86_64
**CPU:** Intel(R) Core(TM) i7-14700KF
**Rust:** rustc 1.92.0 (ded5c06cf 2025-12-08)

## 1. Execution Mode Comparison

| Program | Mode | Wall Time | Cycles | Throughput (cycles/us) | vs ASM |
|---------|------|-----------|--------|----------------------|--------|
| simple64 | Interp64-Sparse | 65.1 us | 2037 | 31.3 | baseline |
| simple64 | Interp64-Flat | 63.3 us | 2037 | 32.2 | -2.7% |
| trace64 | Interp64-Sparse | 48.1 us | 512 | 10.6 | baseline |
| trace64 | Interp64-Flat | 53.3 us | 512 | 9.6 | +10.7% |

## 2. Memory Backend Comparison

| Program | Backend | Wall Time | Cycles | Delta vs Flat |
|---------|---------|-----------|--------|---------------|
| simple64 | FlatMemory | 63.3 us | 2037 | baseline |
| simple64 | SparseMemory | 65.1 us | 2037 | +2.8% |
| trace64 | FlatMemory | 53.3 us | 512 | baseline |
| trace64 | SparseMemory | 48.1 us | 512 | -9.7% |

## 3. Cost Model Consistency

| Program | Mode | Cycles | Exit Code | Match? |
|---------|------|--------|-----------|--------|
| simple64 | Interp64-Sparse | 2037 | 0 | Yes |
| simple64 | Interp64-Flat | 2037 | 0 | Yes |
| trace64 | Interp64-Sparse | 512 | 11 | Yes |
| trace64 | Interp64-Flat | 512 | 11 | Yes |

## Summary

- **ASM mode:** Not available (compiled without `has_asm`)
- **simple64 memory:** FlatMemory and SparseMemory perform similarly (1.03x ratio)
- **trace64 memory:** SparseMemory is 1.1x faster than FlatMemory
- **Cost model:** Consistent across all execution modes

