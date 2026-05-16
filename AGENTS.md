# AGENTS.md
file for tracking state direction and goals of the current project

## Project

A heads-up postflop solver for Texas Hold'em, written from scratch in Zig 0.16 (the latest stable). The goal is to solve flop/turn/river — preflop is out of scope; users will eventually upload their own preflop ranges.

This is not meant to compete with high-end commercial solvers. It is free software intended to run locally on laptops and desktops. We squeeze what performance we can, but the bar is "good and accurate on a personal machine," not "industrial."

## Build & Test

- **Debug build** (catches memory leaks and runs safety checks — use this by default): `zig build`
- **Release build**: `zig build -Doptimize=ReleaseFast`
- **Run all tests**: `zig build test`. Note: in Zig 0.16, `@import` alone doesn't pull a module's tests into the runner — `src/root.zig` ends with a `test { _ = mod; }` block that explicitly references every module so its `test` blocks get collected. **New `.zig` files must be added both as a `pub const X = @import(...)` *and* referenced in that test block**, or their tests will silently report `All 0 tests passed`.
- **Random seeding**: `solve()` takes a `std.Random` from the caller — pass a `std.Random.DefaultPrng.init(42).random()` from tests for determinism, and a high-entropy source (e.g. `std.crypto.random`) from production code.
- **Run tests in a single file**: `zig test src/<file>.zig`

## Architecture

### PokerEval (evaluator.zig)

Hand evaluation uses a rank-histogram approach.
- **Safe Evaluation:** `handStrength` skips cards with value `0`, allowing it to evaluate partial boards (e.g., Flop/Turn) without crashing.
- **Performance:** It is highly optimized but not currently the bottleneck.
- **Straight-Flush Detection:** The SF check runs against the full per-suit rank bitmap, *before* the top-5 popcount reduction. This is required to detect SFs that are hidden underneath higher non-consecutive suited kickers (e.g. a wheel SF with A♠K♠ in hand and 2♠3♠4♠5♠ on board). A regression test in `evaluator.zig` pins this behavior.

### CFR Solver (src/cfr.zig)

The core engine uses **CFR+ with linear-weighted averaging**, on top of **Chance-Sampled CFR (CS-CFR)** with vector-based updates.

#### CFR+ Regret Matching
After each per-iteration regret update, cumulative regrets are clipped to non-negative (`R⁺ = max(R + Δ, 0)`). This is the standard RM+ rule and is the dominant source of the convergence improvement vs vanilla CFR.

#### BoardSnapshot (Cheap Chance Restore)
Chance nodes used to call `reinitForBoard` twice per visit — once to install the sampled runout, once to restore the original board on the way out. Both invocations re-evaluated all 1326 hand strengths and re-sorted them. The restore path is now backed by `BoardSnapshot` (a copy of `hand_strengths`, `blocked`, `sorted_indices`, `rank_map`, `first_rank`, `last_rank`): we snapshot once before mutating, do the recursive walk, then `restoreBoard` is a flat memcpy. `brWalk` benefits even more — it snapshots once before its enumeration loop and restores once at the end, regardless of how many runouts were enumerated.

#### Linear-Weighted Strategy Averaging
Each iteration's contribution to `strategy_sum` is multiplied by `iter + 1`, so the time-averaged strategy that `averageStrategy` returns is dominated by later, near-equilibrium iterations rather than the early uniform-mixture rounds. `iter_weight` is passed top-down through `walk` from `solve`.

**Measured effect:** at 200 iterations, exploitability on the AA-vs-KK river test dropped from ~0.75 (vanilla) to ~0.015 (CFR+), and the polarized-vs-condensed game dropped from low single digits to ~0.016. Both tests now assert `< 0.05`.

#### Optimization: O(N) Terminal Payoffs
Showdown and Fold payoffs are calculated in $O(N)$ time (where $N=1326$ hands) instead of the naive $O(N^2)$.
- **Prefix-Sum Sweep:** Uses a sorted permutation of hands by strength to calculate "naive" EV in one pass.
- **Collision Correction:** Subtracts the reach of the ~101 colliding hands per hand to fix the naive EV.
- **Speedup:** This provided a ~14x performance boost.

#### Optimization: Chance-Sampled CFR (CS-CFR)
Instead of enumerating all possible runouts (47 Turn cards, 46 River cards) at every iteration, the solver samples **one** random runout per `walk`.
- **Logic:** In `walk`, if `is_chance` is true, a random legal card is sampled and added to the board. `reinitForBoard` updates the solver state, and recursion continues.
- **Card Removal:** When a runout is sampled, both players' reach vectors are masked to zero on hands containing the new board card *before* recursing, so downstream regret / strategy_sum updates don't accumulate mass for hands that are illegal on the new board.
- **Best Response:** `bestResponse` and `exploitability` still use **full enumeration** of runouts for exactness. Since these are called infrequently, the $O(\text{runouts})$ cost is acceptable for the precision gain.

#### Strategy Extraction
`averageStrategy(node, out)` normalizes a non-chance node's `strategy_sum` into per-action probabilities per hand, laid out as `out[action * NUM_HANDS + hand_idx]`. This is the public-facing readout from a solved tree (used by the upcoming CLI and by any leaf-evaluator that wants to plug into a parent solve). Hands with zero accumulated mass fall back to uniform.

### Game Tree

The betting tree lives in `src/gamestate.zig` (state machine) and `src/node.zig` (tree structure).

- **Chance Nodes:** Street transitions produce a `Node` with `is_chance = true`. These nodes have exactly one outgoing edge tagged `Action.CHANCE`.
- **Pre-River All-in Runouts:** A call of an all-in pre-river is *not* terminal. `getCallGameState` marks it as a chance state, and `applyChance` chains additional chance steps (one per pending street) until the river is dealt — at which point the post-chance state is `isTerm = true`. This produces a chain like `(call edge) → chance(turn) → chance(river) → terminal showdown` for a FLOP all-in. The chance-terminal showdown is handled inside `walk` / `brWalk` by calling `terminalShowdown` on the chance edge whose child is `null`. CS-CFR samples one runout per chain visit during `walk`; `brWalk` enumerates fully for exactness.
- **Subgame Decomposition:** Currently, the solver can traverse any street, but memory usage scales with tree depth. The intended path is to solve Flops using coarse leaf values and then re-solve Turn/River subgames independently.

## Current State

- **Performance:** `zig build test` takes ~20s for 32 tests (down from ~22s after the `BoardSnapshot` optimization; pre-CFR+/optimization baseline was ~57s for 25 tests). Turn-start solves converge in seconds.
- **Verification:** Convergence is verified on AA-vs-KK toy games (River and Turn) and a "Polarized vs Condensed" range test, with exploitability asserted `< 0.05` after 200 CFR+ iterations. Behavioral correctness is checked by asserting KK folds to a bet on the AA-vs-KK river via `averageStrategy`. Tree structure for pre-river all-in runouts is verified by a `node.zig` structural test. Snapshot/restore round-trip is verified directly.
- **Correctness:** All 32 tests pass.

## Known Gaps & Cautions

- **Memory Scaling:** While fast, a full Flop tree with all runouts stored would be very large. **Subgame Decomposition** is required to solve Flops with limited RAM.
- **HandTable.getIndex:** Still $O(N)$. Fine for current tests, but could be a future bottleneck if used in a hot loop (like `Solver.init`).
- **Walk Stack Footprint:** `walk` allocates ~100 KB of per-call buffers on the stack (`strategy`, `child_cfv_p1/p2`, `new_p1/p2_reach`), plus ~18 KB of `BoardSnapshot` on the chance branch. Fine on default thread stacks today, but a concern once parallelization spawns workers — `MAX_ACTIONS` is over-allocated at 6 vs the real max of 5, and heap-backed scratch buffers are likely cleaner.
- **Street Conventions:** `Street.FLOP/TURN/RIVER` is interpreted by `walk` as "decisions on a board with 3/4/5 cards revealed respectively"; chance nodes deal one card per street transition. The existing turn-start CFR test passes a 3-card board with `Street.TURN`, which the evaluator tolerates (it skips zero cards), but new test setups should use the matching card count for the starting street.

## Next Steps

1.  **CLI/UI (prereq done):** Strategy extraction is now exposed via `averageStrategy`; remaining work is parsing user-supplied ranges/boards and printing the per-action probabilities.
2.  **Subgame Decomposition (Late Solving):** Implement a "Subgame Manager" that can solve the Flop using estimated leaf values and then trigger Turn/River solves on demand.
3.  **Leaf Value Estimation:** Implement a "Cheap Evaluator" (e.g., Equity-based) to provide values for Flop leaf nodes without full River enumeration.
4.  **Parallelization:** Utilize Zig's threading model to parallelize the sampled `walk` iterations or the independent runouts in `bestResponse`. Note: `reinitForBoard` mutates solver-wide state, so parallel chance enumeration needs thread-local strength/sort buffers or a refactor that lifts those into a per-worker context.
