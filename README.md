# Poker

A work-in-progress heads-up postflop solver for Texas Hold'em, written from
scratch in Zig 0.16.

The goal is to build a free local solver that can run on ordinary laptops and
desktops. It is not trying to compete with high-end commercial solvers. The
target is a practical, understandable engine that can solve useful flop, turn,
and river spots with reasonable accuracy and memory use.

## Status

This project is not finished yet. The core engine exists and is covered by a
growing test suite, but the user-facing parts are still early:

- no real CLI yet,
- no range file parser yet,
- no GUI,
- no preflop solver,
- no stable public API guarantee.

The current executable is only a small evaluator demo. Most meaningful behavior
is currently exercised through tests and library-style APIs.

## What Works Today

- 7-card poker hand evaluation with partial-board-safe behavior.
- Heads-up betting state machine for flop, turn, and river.
- Betting tree construction, including chance nodes and pre-river all-in
  runouts.
- CFR+ solver with linear-weighted strategy averaging.
- Chance-sampled CFR during training.
- Exact best-response and exploitability evaluation through full chance
  enumeration.
- O(N) terminal fold/showdown counterfactual values over all 1326 private
  hands, with collision correction.
- Truncated flop and turn trees for subgame decomposition.
- All-in equity leaf evaluator for truncated chance leaves.
- `SubgameManager` support for solving a truncated flop once, collecting chance
  seeds, and resolving selected turns/rivers as fresh subgames.
- Parallel CFR updates and parallelized exploitability paths for the expensive
  solver tests.

## What Is Out Of Scope

- Preflop solving.
- Cloud solving or server deployment.
- Commercial-scale abstraction, bucketing, or production-grade performance.
- Guaranteed compatibility with established solver formats until a range/input
  format is chosen.

Users are expected to provide preflop ranges eventually; this project focuses on
postflop solving.

## Build Requirements

- Zig 0.16.0 or newer compatible 0.16 release.
- No external package dependencies.

The minimum Zig version is declared in `build.zig.zon`.

## Build And Test

```bash
zig build
```

Run all tests:

```bash
zig build test
```

Build with release optimization:

```bash
zig build -Doptimize=ReleaseFast
```

Run the current demo executable:

```bash
zig build run
```

During development, debug builds are preferred because they catch memory leaks
and safety issues. The full test suite is solve-heavy and can take a while in
debug mode.

## Project Layout

```text
src/card.zig       Card representation and deck helpers
src/evaluator.zig  Poker hand evaluator
src/range.zig      Hand table and dense range storage
src/gamestate.zig  Betting state machine
src/node.zig       Game tree nodes and tree builders
src/cfr.zig        CFR+ solver, CFVs, BR, exploitability
src/subgame.zig    Subgame decomposition orchestration
src/main.zig       Temporary evaluator demo
src/root.zig       Module aggregator and test collector
```

## Solver Design

The engine uses CFR+ with regret matching and non-negative regret clipping.
Strategy averaging is linearly weighted so later iterations contribute more to
the public `averageStrategy` result.

Chance-sampled CFR is used during training: public runouts are sampled in the
walker rather than fully enumerated every iteration. Exact best response,
exploitability, and all-in equity leaves still enumerate public runouts so the
verification paths are deterministic and precise.

Full flop trees can become too large if every turn and river runout owns a full
betting subtree. The current architecture handles this with subgame
decomposition:

1. Solve a flop tree truncated at the turn chance boundary.
2. Evaluate truncated leaves with an all-in equity model.
3. Collect chance seeds using the averaged strategy.
4. Resolve selected turn cards as fresh turn subgames.
5. Resolve selected river cards as full river subgames.

This keeps the working set to one street-level problem at a time.

## Verification

The test suite currently covers:

- evaluator correctness, including straight-flush edge cases,
- betting transitions and all-in constraints,
- chance-node and truncated-tree structure,
- blocker-aware chance denominators,
- board snapshot/restore behavior,
- parallel worker board-state isolation,
- CFR convergence on compact AA-vs-KK and polarized/condensed games,
- average strategy extraction,
- all-in equity leaf consistency against exact runout enumeration,
- flop-to-turn and turn-to-river subgame construction.

Run `zig build test` before relying on a change.

## Roadmap

Near-term engine work:

1. Characterize release-build parallel CFR performance against serial behavior.
2. Add benchmark tooling for truncated-subgame accuracy.
3. Compare the current all-in equity leaf model against alternate leaf models.
4. Cache runout `BoardContext`s for repeated all-in equity leaf evaluations.
5. Replace linear `HandTable.getIndex` lookup if it shows up in hot paths.
6. Move large walker scratch buffers off the stack if worker stack pressure
   becomes a practical issue.

User-facing work after the engine is steadier:

1. Define or adopt a range input format.
2. Add a minimal CLI for ranges, boards, solve configuration, and strategy
   output.
3. Expose useful reports from `averageStrategy`.
4. Consider a UI only after the CLI and engine APIs are solid.

## Development Notes

New source modules need to be added to `src/root.zig` twice: once as a `pub const`
import and once in the final `test { ... }` block. Without the test-block
reference, Zig may skip tests from that module.

Randomized solver tests should use deterministic `std.Random.DefaultPrng` seeds.

## License

No license file has been added yet.
