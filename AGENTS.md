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

## Commands

- Debug build: `zig build`
- Release build: `zig build -Doptimize=ReleaseFast`
- Run all tests: `zig build test`
- Run one file's tests while iterating: `zig test src/<file>.zig`
- Run demo executable: `zig build run`

Use debug builds/tests by default because they catch leaks and safety issues.
Use deterministic test RNGs, usually:

```zig
var prng = std.Random.DefaultPrng.init(42);
const random = prng.random();
```

Zig 0.16 notes:

- Use `std.Io` APIs for production entropy; `std.crypto.random` convenience is
  gone.
- Adding a new `.zig` module requires both `pub const name = @import(...)` in
  `src/root.zig` and a reference in its final `test { _ = name; }` block.
  Otherwise module tests can silently be skipped.

## Module Map

- `src/card.zig` - compact card representation, deck construction, card text.
- `src/evaluator.zig` - rank-histogram hand evaluator.
- `src/range.zig` - `Hand`, `HandTable`, dense range probabilities.
- `src/gamestate.zig` - betting state machine and street transitions.
- `src/node.zig` - betting tree nodes/edges and full/truncated tree builders.
- `src/cfr.zig` - CFR+ solver, chance sampling, terminal CFVs, BR/exploitability.
- `src/subgame.zig` - `Subgame` and `SubgameManager` orchestration for truncated
  flop/turn solves and river re-solves.
- `src/main.zig` - evaluator demo only; not yet a real CLI.
- `src/root.zig` - public module aggregator and test collector.

## Solver Invariants

Keep these contracts intact unless deliberately changing the solver design:

- `NUM_HANDS` is 1326. Strategy/regret vectors are laid out as
  `action * NUM_HANDS + hand_index`.
- Boards are `[5]Card`; unused public card slots are `0`. Evaluator logic must
  tolerate partial boards.
- `Street.FLOP`, `.TURN`, and `.RIVER` mean decisions with 3, 4, and 5 public
  cards revealed. Chance nodes deal one public card per street transition.
- A pre-river all-in call is not terminal. It becomes a chance chain until the
  river board is complete, then terminal showdown is evaluated.
- Normal chance nodes have one `Action.CHANCE` edge. Truncated chance leaves set
  `is_chance = true` and `is_leaf = true`, then evaluate through
  `SolveContext.allInEquityLeaf`.
- Public runouts are sampled in `walk` for CS-CFR, but `bestResponse`,
  `exploitability`, and `allInEquityLeaf` enumerate runouts exactly.
- Chance handling must mask private hands blocked by newly dealt public cards.
  Per-hand chance denominators are blocker-conditioned, e.g. a turn-to-river
  private hand may have 46 legal rivers. Flop leaves enumerate *unordered*
  (turn, river) pairs and use `legalRunoutCount` with `cards_to_deal = 2`
  returning `(public_count - 2) * (public_count - 3) / 2`.
- CFR is CFR+ with regret matching plus non-negative regret clipping after each
  update. `strategy_sum` uses linear iteration weights (`iter + 1`).
- `averageStrategy(node, out)` is the public strategy readout. It returns the
  linear-weighted average strategy, not the latest instantaneous strategy.
- Showdown/fold CFVs are O(N) prefix-sweep implementations with collision
  correction. Avoid reintroducing O(N^2) terminal payoff loops.
- Board-derived mutable state lives in `BoardContext`. Traversal state lives in
  `SolveContext`. Parallel workers must use separate `BoardContext`s and private
  `WorkerDeltas`; shared tree regrets/strategy sums are merged only after worker
  walks finish.
- `Solver.max_workers` (0 = default cap) and `Solver.timings_io` (null = no
  collection) are bench/diagnostic knobs. Tests leave both at defaults and pay
  zero overhead. The bench's `WORKER_SWEEP` array runs each scenario across
  worker counts and prints per-iter spawn/join/merge µs for the parallel path.
- `Solver.runout_cache` is an eager, per-`Solver` array of pre-computed 5-card
  `BoardContext`s for every legal runout off the solver's root board. Built by
  `Solver.buildRunoutCacheIfNeeded`, which `cfr.solve` calls before dispatching
  any workers. It is read-only by the time workers run, so the fast path in
  `SolveContext.allInEquityLeaf` reads it without synchronization. The slow
  path (recompute on demand) is preserved for callers that bypass `cfr.solve`.

## Subgame Decomposition

Full flop trees are too large when every turn and river runout has a full
betting subtree. The implemented approach is:

- Solve flop trees truncated at the turn boundary.
- Use `allInEquityLeaf` as the v1 leaf model at truncated chance leaves.
- Collect first chance-boundary `ChanceSeed`s from average-strategy reach
  propagation.
- Resolve selected turns from seeds as fresh turn subgames truncated at river.
- Resolve selected rivers as fresh full river subgames.

Use path-based seed selection (`PathStep` action plus edge amount) when possible;
array order is not a stable external identifier.

## Verification Expectations

Before handing off solver changes, run at least `zig build test`. For tight
inner-loop edits, also run the relevant single-file test command first.

Existing tests cover:

- hand evaluator categories and hidden straight-flush regression,
- betting state transitions, all-in constraints, and chance-state restrictions,
- tree structure for chance nodes, all-in runouts, and truncated leaves,
- board snapshot/restore and `SolveContext` isolation,
- CFR convergence on compact AA-vs-KK and polarized/condensed games,
- average strategy extraction,
- per-hand blocker-conditioned chance counts,
- all-in equity leaf behavior and exact-runout consistency,
- subgame construction, chance-seed collection, turn/river re-solves, and
  truncated flop topology size.

## Known Gaps

- `HandTable.getIndex` is still linear. It is fine for current tests, but do not
  put it in a hot loop without replacing it.
- `walk`/`brWalk` still keep large scratch buffers on the stack. This is
  acceptable today but should be heap-backed before relying on arbitrary worker
  stack sizes.
- Full-topology truncated exploitability is too expensive for the default unit
  suite. Put deeper accuracy studies in benchmark-style tests or separate tools.
- The runout cache stores full `BoardContext`s (~17 KB each, so ~20 MB for a
  flop solve). Acceptable today; if memory tightens, the cache could shrink
  to per-hand strength + rank arrays (the actually-read fields).
- There is no real CLI/range parser yet. Investigate existing range formats
  before inventing one.

## Current Priorities

Engine work comes before UI:

1. Add a minimal CLI/range input path. Engine is in a good shape (fast
   leaf eval after the runout cache; parallel scaling confirmed to be
   working at ~7× on the expensive flop workload). Investigate existing
   range formats (PokerStove-style, GTO+ exports, etc.) before inventing
   one.
2. Extend `src/bench.zig` for truncated-subgame accuracy and alternate
   leaf models (v2+ models beyond `allInEquityLeaf`).
3. Replace `HandTable.getIndex` with a constant-time lookup if it
   becomes hot. Currently only used in setup/tests, so low priority.

**Deferred / deprioritized (with reasons):**

- *Thread pooling for `cfr.solve`*: profile data (`spawn_ns` ~1.5 ms/iter
  at 8 workers) shows spawn cost is a small share of wall-clock for turn
  (~2%) and flop (~0.03%) workloads. Only river-polarized would
  meaningfully benefit (~13%), and that scenario is already cheap.
  Reconsider if a future workload spawns many workers per cheap iter.
- *Reducing cache contention on shared regret/strategy_sum reads*: the
  per-iter `join_ns` (≈ max walk wall-clock) grows 12-26% from 2 → 8
  workers on identical work, but samples/s scaling on the expensive flop
  workload is already ~7× of serial. Engineering effort to shave the
  remaining 14% is small absolute win. Reconsider if profiling at higher
  worker counts (16+, on bigger boxes) shows it dominates.

**Parallel-CFR semantics (load-bearing):**

Each parallel iter spawns `n_workers` walks; each walk samples one chance
path and writes its own deltas; `mergeDeltas` aggregates after the iter.
Adding workers *does not* speed up a single iter — it adds more sample
paths per iter for variance reduction. Wall-clock per iter grows with
worker count (more total walk work plus mild cache contention) but
per-sample throughput rises. Read `samples/s` (not `iters/s`) for the
honest parallel scaling number; `iters/s` is the strategy-update rate.
On a 16-core box at 8 workers: flop-trunc ~7×, turn-fullrange ~4.5×,
river-polarized ~3.7× sample-throughput speedup vs serial.

When completing a substantial change, update this file with durable new
contracts, commands, caveats, or priorities. Do not add a blow-by-blow progress
log.
