# AGENTS.md

Operational guide for agents working on this repository.

<!-- codebase-memory-mcp:start -->
## Codebase Discovery

This project is indexed by `codebase-memory-mcp`. Prefer graph tools over raw
text search when discovering code:

1. `search_graph` - find functions, types, tests, and modules.
2. `trace_path` - inspect callers, callees, and impact.
3. `get_code_snippet` - read exact function/type source after graph search.
4. `query_graph` - answer multi-hop or aggregate questions.
5. `get_architecture` - get a high-level project summary.

Fall back to `rg` for string literals, config/docs, or when graph results are
insufficient.
<!-- codebase-memory-mcp:end -->

## Project Intent

This is a heads-up postflop Texas Hold'em solver written from scratch in Zig
0.16. It targets flop, turn, and river solving only. Preflop solving is out of
scope; users will eventually provide preflop ranges.

The target is free local software for laptops and desktops: correct,
reasonably fast, and memory-conscious, not a commercial-scale solver.

## Agent Constraints (CRITICAL)

- **Zig 0.16 Style**: Adhere to `std.Io` for I/O and entropy. Use `ArenaAllocator`
  for tree-like data structures. Prefer `usize` for indices.
- **No Performance Regressions**: Any change to `src/cfr.zig` or `src/evaluator.zig`
  must be benchmarked using `zig build -Doptimize=ReleaseFast bench`.
- **Validation**: Every bug fix must include a regression test in the relevant
  file. Every new feature must include unit tests.
- **Memory Safety**: Do not use `allow_multiple` in `replace` unless absolutely
  necessary. Check for memory leaks using debug builds (`zig build test`).

## Commands

- Debug build: `zig build`
- Release build: `zig build -Doptimize=ReleaseFast`
- Run all tests: `zig build test`
- Run one file's tests while iterating: `zig test src/<file>.zig`
- Run the CLI: `./zig-out/bin/Poker solve --board AhKsQd --pot 50
  --stack 200 --p1 "JJ+, AKs" --p2 "TT+, AQs+" --iters 20 --truncate flop`
  (build first with `zig build -Doptimize=ReleaseFast`).
- Run benchmark: `zig build -Doptimize=ReleaseFast bench`.

## Module Map

- `src/card.zig` - Compact `u32` card representation, deck construction, card text.
- `src/evaluator.zig` - Rank-histogram hand evaluator. Highly optimized bitwise logic.
- `src/range.zig` - `Hand`, `HandTable`, dense range probabilities.
- `src/range_parser.zig` - PokerStove-style text → `Range` parser, plus `parseBoard`.
- `src/gamestate.zig` - Betting state machine and street transitions.
- `src/node.zig` - Betting tree nodes/edges and full/truncated tree builders.
- `src/cfr.zig` - CFR+ solver core, chance sampling, parallel walk dispatch.
- `src/subgame.zig` - `Subgame` and `SubgameManager` orchestration for re-solves.
- `src/main.zig` - `poker solve` CLI entry point and argument parsing.

## Solver Invariants

- `NUM_HANDS` is 1326. Strategy/regret vectors are `action * NUM_HANDS + hand_index`.
- `BoardContext` contains all board-mutable state; `SolveContext` is per-worker.
- `allInEquityLeaf` is the default model for truncated chance nodes.
- Showdown/fold CFVs use O(N) prefix-sweeps with collision correction.
- `Solver.init` requires `io: std.Io` (used by the parallel-pool sync
  primitives and the optional `record_timings` accumulator). Binaries pass
  `init.io`; tests pass `std.testing.io`.
- `walk` / `brWalk` are depth-indexed: callers pass `depth = 0`, recursion
  advances. Per-frame scratch lives in `SolveContext.scratch` (heap-allocated
  via `WalkScratch.init`). `MAX_WALK_DEPTH` is the hard ceiling — asserts at
  function entry catch overflow. Contexts that only invoke terminal helpers
  (no walk recursion) can use `WalkScratch.empty`.
- `cfr.exploitability` and `cfr.bestResponse` now take an `Allocator`. Tests
  use `std.testing.allocator`; production paths thread through the same
  allocator already used for the rest of the solve.

## Known Gaps & Slop

- **UI/CLI**: No per-hand strategy export or CSV output.
- **Subgame**: `SubgameManager` is functional but not exposed via CLI.
- **Performance (deferred, low ROI)**: `brWalk`'s chance-runout parallelism
  still uses `std.Thread.spawn` per dispatch. Only one dispatch happens per
  top-level brWalk traversal (workers run with `allow_parallel = false`), so
  per-`exploitability` spawn cost is ~16 spawns ≈ 5ms — not worth a pool
  rewrite given exploitability is a verification path called rarely.

## Current Priorities

1. **Features**: Add `poker resolve-turn` and `poker resolve-river` CLI commands.
