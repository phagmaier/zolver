# Solver Optimization & Stability Plan

This document outlines the critical technical concerns identified in the Poker Solver codebase and provides a phased plan for remediation.

## 1. Critical Technical Concerns

### 1.1 Stack Exhaustion Risk (High Severity)
*   **The Issue**: The recursive `walk()` and `brWalk()` functions in `cfr.zig` allocate ~90 KB of local variables per frame. With deep betting trees and chance nodes, recursion depth can exceed 10–15 levels, consuming >1.3 MB of stack.
*   **Why it Matters**: Parallel workers in Zig often have smaller stack limits. A complex tree will cause a non-deterministic stack overflow, which is difficult to debug and leads to hard crashes.

### 1.2 Performance Bottleneck: HashMap Lookups (High Severity)
*   **The Issue**: The parallel solver performs multiple `HashMap.get(node)` calls per node visit in the inner loop to retrieve worker-specific delta buffers.
*   **Why it Matters**: At millions of iterations, the hashing overhead and potential cache misses from map lookups significantly degrade throughput. Inner loops must be $O(1)$ with minimal constant overhead.

### 1.3 Computational Explosion: Flop Leaf Evaluation (High Severity)
*   **The Issue**: `allInEquityLeaf` exactly enumerates 2,352 runouts for every flop leaf visit.
*   **Why it Matters**: This makes flop solves computationally impractical. A single CFR iteration would spend nearly all its time re-calculating identical equity values at the same leaves.

### 1.4 Algorithmic Inefficiency: Linear Hand Lookups (Medium Severity)
*   **The Issue**: `HandTable.getIndex` uses linear search, and `Subgame.maskReachForCard` repeatedly re-initializes the entire `HandTable`.
*   **Why it Matters**: While not in the absolute hottest loop, these $O(N)$ operations and redundant allocations add up during subgame orchestration and initialization.

---

## 2. Proposed Implementation Plan

### Phase 1: Memory Safety & Architecture (Stack Fix)
*   **Action**: Refactor `SolveContext` to hold reusable scratch buffers for `strategy`, `child_cfv`, and `reach` vectors.
*   **Action**: Modify `walk()` and `brWalk()` to use these buffers from the context instead of stack allocation.
*   **Verification**: Ensure no regression in single-threaded tests and check stack usage via `zig build test`.

### Phase 2: Performance Core (ID-based Lookups)
*   **Action**: Add a unique `u32 id` field to `Node`. Update `buildTree` to assign these IDs sequentially.
*   **Action**: Replace `HashMap` in `WorkerDeltas` with a simple array/slice indexed by `node.id`.
*   **Verification**: Benchmark iteration speed (iterations per second) before and after.

### Phase 3: Algorithmic Optimization (HandTable & Caching)
*   **Action**: Implement a `[52][52]u16` lookup table in `HandTable` for $O(1)$ index retrieval.
*   **Action**: Update `Subgame` and `Solver` to share a single pre-initialized `HandTable`.
*   **Action**: Implement an `equity_cache` in the `Node` structure for truncated leaves. Calculate `allInEquityLeaf` only once per node and store the result.
*   **Verification**: Run a full flop solve and verify the time reduction.

### Phase 4: Robustness & Refinement
*   **Action**: Replace `std.debug.print` in `card.zig` with `std.debug.assert` and proper error propagation.
*   **Action**: Consolidate `1e-3` epsilon constants into a single `constants.zig` or `root.zig` definition.
*   **Verification**: Run full suite `zig build test`.

---

## 3. Success Criteria
1.  **Stability**: Zero stack overflows on trees with 5+ bet sizes.
2.  **Speed**: At least 2x-5x improvement in iterations per second for parallel solves.
3.  **Correctness**: Exploitability remains bounded and converging on all existing test cases.
