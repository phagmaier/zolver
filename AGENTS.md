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
- **External deps**: only one — [libvaxis](https://github.com/rockorager/libvaxis)
  (TUI library), pinned in `build.zig.zon`. Linked into the exe but not into
  the `Poker` module that hosts the test suite, so library code outside
  `src/tui.zig` must not depend on it.
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
- Re-solve a turn/river subgame: `./zig-out/bin/Poker resolve examples/turn.zon`
  (or `examples/river.zon`). The spec file declares board, ranges, pot, stack,
  iters, flop path, turn card, and optional river path + card. Path tokens are
  whitespace-separated: `x`=check, `c`=call, `f`=fold, `j`=allin, `b<pct>`=bet
  (sized from `gamestate.BETSIZES`, e.g. `b50`, `b100`).
- Launch the TUI: `./zig-out/bin/Poker tui [spec.zon]`. Optional path
  pre-fills the form. Keybindings: Tab/↑↓ navigate fields, Enter (or Ctrl+R)
  solves, Ctrl+S saves the form back to `spec.zon` as ZON, Esc/Ctrl+C quits,
  PgUp/PgDn scroll the strategy table. Requires a real TTY (`/dev/tty`).
  The board field is the full runout (`AhKsQdTh` for a turn resolve,
  `AhKsQdTh2s` for a river resolve); `flop path` becomes required when the
  board has 4+ cards, `turn path` when it has 5. The TUI is the resolve
  front-end only — 3-card flop-only solves go through `poker solve`.
- Run benchmark: `zig build -Doptimize=ReleaseFast bench`.

## Module Map

- `src/card.zig` - Compact `u32` card representation, deck construction, card text.
- `src/evaluator.zig` - Rank-histogram hand evaluator. Highly optimized bitwise logic.
- `src/range.zig` - `Hand`, `HandTable`, dense range probabilities.
- `src/range_parser.zig` - PokerStove-style text → `Range` parser, plus `parseBoard`.
- `src/gamestate.zig` - Betting state machine and street transitions.
- `src/node.zig` - Betting tree nodes/edges and full/truncated tree builders.
- `src/cfr.zig` - DCFR solver core, chance sampling, parallel walk dispatch.
  Per-hand inner loops are SIMD-vectorized via `@Vector(VEC_LANES, f32)`
  (`VEC_LANES = std.simd.suggestVectorLength(f32) orelse 8`), with a scalar
  tail handling the `NUM_HANDS % VEC_LANES` remainder.
- `src/subgame.zig` - `Subgame` and `SubgameManager` orchestration for re-solves.
- `src/spec.zig` - ZON spec file types and path-token parser for `poker resolve`.
  Header comment is the canonical reference for the spec file grammar.
- `src/export.zig` - CSV writer for per-hand root strategy. Header comment
  documents the schema.
- `src/tui.zig` - libvaxis-backed interactive form for editing a spec,
  triggering the resolve, viewing the per-hand strategy, and saving the spec
  back to disk as ZON.
- `src/main.zig` - `poker solve` / `poker resolve` / `poker tui` CLI entry
  points and dispatch.
- `examples/turn.zon`, `examples/river.zon`, `examples/turn_with_export.zon` -
  Sample specs (the last enables CSV export + exploitability). Any of these
  works as input to `poker tui` too.

## Solver Invariants

- `NUM_HANDS` is 1326. Strategy/regret vectors are `action * NUM_HANDS + hand_index`.
  This layout is action-major on purpose so the inner loops vectorize cleanly
  across the hand axis; do not transpose.
- The solver uses **DCFR** (Brown & Sandholm 2019) with (α=1.5, β=0, γ=2).
  Cumulative regret storage is *signed* — negative regrets accumulate and
  decay at half-rate per iter (β=0 gives a constant 0.5 neg-discount).
  Regret matching at the start of each walk reads `max(0, R)` when computing
  the current strategy, so storage stays signed without breaking the
  read path. Per-iter discounts are precomputed in `DcfrWeights.forIter`.
- `BoardContext` contains all board-mutable state; `SolveContext` is per-worker.
- `allInEquityLeaf` is the default model for truncated chance nodes.
- Showdown/fold CFVs use O(N) prefix-sweeps with collision correction. The
  collision-correction inner loop is SIMD-vectorized via manual gather +
  masked `@select` on `s_j < s_i` / `s_j > s_i`.
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

- **TUI blocks the event loop while solving.** The form remains responsive
  until the user presses Enter; while CFR runs, the UI is frozen and even
  Esc/Ctrl+C are buffered (raw mode prevents them from sending signals).
  The pre-solve render now paints "Solving... UI is frozen until done" so
  the user sees the freeze is intentional. Real fix needs a worker thread.
- **Bet sizes are hardcoded.** `gamestate.BETSIZES = .{0.5, 1.0}` is a
  single global list shared across flop/turn/river; `MAXNUMBETS = 2` caps
  raises. Not configurable from CLI, spec, or TUI. The next priority is
  threading a per-street bet-size list + cap through `GameState`,
  `node.buildTree`, `spec`, and `main`. Current Priorities #1.
- **CLI is still kept around** (`poker solve` / `poker resolve`) for
  scripting and one-shots. It's not deprecated, but the TUI is now the
  intended interactive surface.
- **`card.get_card_str` returns uppercase suits** (`AHKSQD`), which doesn't
  match the parser's expected lowercase input (`AhKsQd`). Cosmetic only — the
  parser is case-insensitive on suits — but the `resolve` summary's "full
  board" line is jarring. Fix by lowercasing the suit letters in
  `card.get_card_str` if anything else starts depending on that output.
- **Performance (deferred, low ROI)**: `brWalk`'s chance-runout parallelism
  still uses `std.Thread.spawn` per dispatch. Only one dispatch happens per
  top-level brWalk traversal (workers run with `allow_parallel = false`), so
  per-`exploitability` spawn cost is ~16 spawns ≈ 5ms — not worth a pool
  rewrite given exploitability is a verification path called rarely.
- **Sparse hand iteration not implemented.** Inner per-hand loops walk all
  1326 hands unconditionally even when a player's range has 50 active hands.
  Skipping all-zero vector blocks is doable but interacts subtly with the
  DCFR strategy_sum discount (must still apply to existing storage) and
  with counterfactual regret accumulation (which is nonzero even when reach
  is zero). Defer until a narrow-range workflow actually feels slow.

## Current Priorities

1. **Per-street bet sizes + cap.** Replace `gamestate.BETSIZES` and
   `MAXNUMBETS` with a configurable `BetAbstraction` (per-street lists +
   cap), thread it through `GameState.getBetGameState`, `node.buildTree`,
   `spec.zig`, `main.zig` (CLI flag), and `tui.zig`. Users currently can't
   solve a real spot with a meaningful sizing tree (always 50% + 100% + all-in)
   — this is the biggest "make it usable" lever after the perf pass.
2. **Background solve in TUI.** Solve currently blocks the TUI event loop
   — at `iters=200` on a real spot this is multiple minutes of frozen UI.
   Move the solve to a worker thread, post events back to the loop, paint
   a progress indicator.
3. **Preflop range pipeline.** Preflop solving is out of scope, but the TUI
   will eventually want to accept user-supplied preflop ranges and feed them
   into postflop spots. No code for this exists yet — every entry point
   takes ranges as strings or `@path` references via `range_parser`.
4. **Whole-tree strategy export / navigation.** Current CSV (and the in-TUI
   table) is root-only. Once a user wants to drill into a subtree, we need
   either a row-per-(node, hand, action) CSV mode or a tree-navigation view
   in the TUI. Deferred until someone actually needs it.
5. **TUI polish.** Color-coded heatmap on strategy frequencies, real
   resize-aware layout (currently fixed positions), a proper checkbox for
   the `exploit` boolean instead of typing "true"/"false", validation
   feedback as you Tab between fields rather than only on solve attempt.

## Recent Perf Work

Last performance pass landed:

- **SIMD inner loops** in `walk`, `brWalk`, `allInEquityLeaf`,
  `computeShowdownCFVFor`, `terminalFold` — `@Vector(VEC_LANES, f32)` over
  the hand axis with a scalar epilogue. The showdown CFV's
  collision-correction loop uses manual gather + `@select` to drop the
  data-dependent branch.
- **CFR+ → DCFR** for the regret/strategy-sum update. Drop-in replacement;
  see `DcfrWeights.forIter`. Per-iter cost is essentially unchanged;
  convergence per iter is meaningfully better.
- **Bench scenarios**: added `flop-fullrange-100bb-trunc` (pot 10, stack
  1000) as the canonical user-target spot for future regression tests.

Workers=1 wall-clock results on the four bench scenarios (ReleaseFast,
AVX2-class CPU):

| scenario | before | after | speedup |
| --- | --- | --- | --- |
| river-polarized (200 iters) | 1.00s | 0.67s | 1.50× |
| turn-fullrange (50 iters) | 1.92s | 1.23s | 1.56× |
| flop-fullrange-trunc (1 iter) | 4.99s | 2.82s | 1.77× |
| flop-fullrange-100bb-trunc (1 iter) | 4.94s | 2.85s | 1.73× |

The full 200-iter `poker solve` on the flop-100bb spot takes ~13 minutes
wall (16-core machine, parallel) — usable but still long. DCFR's
convergence improvement means fewer iters are typically needed to reach a
target exploitability than CFR+ required.
