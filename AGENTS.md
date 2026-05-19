# AGENTS.md

Operational guide for agents working on this repository.

<!-- codebase-memory-mcp:start -->
## Codebase Discovery
This project is indexed by `codebase-memory-mcp`. **ALWAYS** prefer graph tools over raw text search:
1. `search_graph` - find functions, types, and modules.
2. `trace_path` - inspect callers/callees and impact analysis.
3. `get_architecture` - get a high-level project summary.
<!-- codebase-memory-mcp:end -->

## Project Intent
Postflop Texas Hold'em solver (Flop/Turn/River) in Zig 0.16. 
**Target**: High-performance, memory-conscious local software. Correctness > speed, but speed is a close second.

## Agent Constraints (CRITICAL)
- **Zig 0.16 Style**: Use `std.Io` for I/O. Use `ArenaAllocator` for trees. Prefer `usize` for indices.
- **External Deps**: ONLY `libvaxis` (TUI). Keep it isolated in `src/tui.zig`.
- **SIMD Layout**: Strategy/regret vectors are `action * NUM_HANDS + hand_index`. This is action-major for SIMD vectorization across the hand axis. **Do not transpose.**
- **Perf Validation**: Any change to `src/cfr.zig` or `src/evaluator.zig` **must** be benchmarked: `zig build -Doptimize=ReleaseFast bench`.
- **Inclusion-Exclusion**: Showdown/fold CFVs use an O(N + 52) streaming accumulator. Do not revert to O(N²) collision checks.

## Current Priorities (In Order)
1. **Dynamic Bet Sizing**: Replace hardcoded `BETSIZES` in `gamestate.zig` with a per-street configurable `BetAbstraction`.
2. **Background Solving (TUI)**: The TUI currently freezes during solves. Move `Solver.solve()` to a worker thread and post progress events.
3. **Persistence**: Save/Load `.strategy` files (dense binary dumps) to avoid re-solving identical spots.
4. **Sparse Iteration**: Skip hand-vector blocks where reach mass is zero (high potential ROI for narrow ranges).

## Module Map
- `src/cfr.zig`: **Hot Path.** DCFR core. SIMD-vectorized inner loops.
- `src/gamestate.zig`: Betting state machine. Defines valid actions and transitions.
- `src/node.zig`: Tree construction. Arena-allocated nodes and edges.
- `src/evaluator.zig`: Rank-histogram hand evaluator. Bitwise heavy.
- `src/subgame.zig`: Orchestrates re-solving turns/rivers from a spec.
- `src/tui.zig`: Vaxis-based UI. Handled via event loop.

## Known Gaps
- **TUI UI Freeze**: Solve blocks the main thread.
- **Bet Sizes**: Currently locked to `{0.5, 1.0}` and 2-bet cap.
- **Case Sensitivity**: `card.get_card_str` returns uppercase; parser prefers lowercase.

---

## Technical Appendix: Algorithm Invariants
- **Algorithm**: DCFR (α=1.5, β=0, γ=3) with power-of-4 strategy-sum reset.
- **Regrets**: Signed storage. Negative regrets decay at a constant 0.5 rate (β=0).
- **Strategy sum**: γ=3 applied to `t' = t − floor_pow4(t)` rather than `t`, so at iters 1, 4, 16, 64, 256, ... the average strategy is rebased — only the most-recent power-of-4 window contributes to the reported average. This concentrates the average on late-iter strategies and converges faster in chips/iter (~2× on flop-fullrange-trunc at high-quality targets, ~20× on small river spots). **Sampling caveat:** never measure exploit at iter ∈ {4^k}; the harness uses off-boundary checkpoints (3, 7, 15, 31, 63, ...) for this reason.
- **Showdown CFV**: `accumulateShowdownCFVFor` is the canonical entry — accumulating, blocked-aware, called from both the cached and uncached chance-leaf paths. Reach is fed **un-masked**; per-leaf masking is replaced by inline `blocked[oj]` skipping in the opp accumulator and skipping non-write on `blocked[pi]` for the player. Do NOT call `computeShowdownCFVFor` with pre-masked reach from a leaf — its assignment semantics (out[pi] = ...) clobber accumulated state.
- **Precision**: Use `f64` for walk-side reductions and lane sums to prevent drift over 1326 lanes.
- **Vectorization**: `VEC_LANES` is auto-detected; scalar tail handles `NUM_HANDS % VEC_LANES`.

## Development History (Archived)
<details>
<summary>Recent Performance Gains</summary>

- **Inclusion-Exclusion**: Replaced O(N²) collision loops with O(N+52) passes. (4-8x speedup).
- **Atomic Pool**: Replaced Mutex/CondVar with atomic spin-waits for worker sync.
- **Parallel Merge**: `mergeDeltas` is now multi-threaded across node slices.
- **Leaf-fusion**: Folded the per-cached-runout SIMD wrapper (keep_mask fill + 2 reach-mask passes + 2 output-mask passes) into `accumulateShowdownCFVFor`. ~5-10% per-iter on flop spots; surfaced+fixed a latent slow-path bug where board-blocked hands with nonzero user reach were included in the opp accumulator.
- **DCFR γ=3 + power-of-4 reset**: Switched from γ=2 / no-reset to postflop-solver's γ=3 / `t' = t − floor_pow4(t)` formulation. ~2× wall-clock to high-quality flop exploit; ~20× on small river spots. α/β untouched (the Rust `(t-1)` α-shift breaks the trunc-vs-full subgame verification on point ranges; γ-only change passes both).
</details>
