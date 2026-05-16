# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

A heads-up postflop solver for Texas Hold'em, written from scratch in Zig 0.16 (the latest stable). The goal is to solve flop/turn/river — preflop is out of scope; users will eventually upload their own preflop ranges.

This is not meant to compete with high-end commercial solvers. It is free software intended to run locally on laptops and desktops. We squeeze what performance we can, but the bar is "good and accurate on a personal machine," not "industrial."

## Build & Test

- **Debug build** (catches memory leaks and runs safety checks — use this by default): `zig build`
- **Release build**: `zig build -Doptimize=ReleaseFast`
- **Run all tests**: `zig build test`. Note: in Zig 0.16, `@import` alone doesn't pull a module's tests into the runner — `src/root.zig` ends with a `test { _ = mod; }` block that explicitly references every module so its `test` blocks get collected. **New `.zig` files must be added both as a `pub const X = @import(...)` *and* referenced in that test block**, or their tests will silently report `All 0 tests passed`.
- **Run tests in a single file**: `zig test src/<file>.zig`

## Architecture

### PokerEval (evaluator.zig)

Hand evaluation uses a rank-histogram approach.
- **Safe Evaluation:** `handStrength` skips cards with value `0`, allowing it to evaluate partial boards (e.g., Flop/Turn) without crashing.
- **Performance:** It is highly optimized but not currently the bottleneck.

### CFR Solver (src/cfr.zig)

The core engine uses **Chance-Sampled CFR (CS-CFR)** with vector-based updates.

#### Optimization: O(N) Terminal Payoffs
Showdown and Fold payoffs are calculated in $O(N)$ time (where $N=1326$ hands) instead of the naive $O(N^2)$.
- **Prefix-Sum Sweep:** Uses a sorted permutation of hands by strength to calculate "naive" EV in one pass.
- **Collision Correction:** Subtracts the reach of the ~101 colliding hands per hand to fix the naive EV.
- **Speedup:** This provided a ~14x performance boost.

#### Optimization: Chance-Sampled CFR (CS-CFR)
Instead of enumerating all possible runouts (47 Turn cards, 46 River cards) at every iteration, the solver samples **one** random runout per `walk`.
- **Logic:** In `walk`, if `is_chance` is true, a random legal card is sampled and added to the board. `reinitForBoard` updates the solver state, and recursion continues.
- **Best Response:** `bestResponse` and `exploitability` still use **full enumeration** of runouts for exactness. Since these are called infrequently, the $O(\text{runouts})$ cost is acceptable for the precision gain.

### Game Tree

The betting tree lives in `src/gamestate.zig` (state machine) and `src/node.zig` (tree structure).

- **Chance Nodes:** Street transitions produce a `Node` with `is_chance = true`. These nodes have exactly one outgoing edge tagged `Action.CHANCE`.
- **Subgame Decomposition:** Currently, the solver can traverse any street, but memory usage scales with tree depth. The intended path is to solve Flops using coarse leaf values and then re-solve Turn/River subgames independently.

## Current State

- **Performance:** `zig build test` takes ~11s for 27 tests (down from 57s for 25 tests before optimizations). Turn-start solves converge in seconds.
- **Verification:** Convergence is verified on AA-vs-KK toy games (River and Turn) and a "Polarized vs Condensed" range test.
- **Correctness:** All 27 tests pass.

## Known Gaps & Cautions

- **Memory Scaling:** While fast, a full Flop tree with all runouts stored would be very large. **Subgame Decomposition** is required to solve Flops with limited RAM.
- **All-in Pre-River:** Verify that `buildTree` and `terminalShowdown` correctly handle pre-river all-ins (they should effectively become chance-sampled showdowns at the River).
- **HandTable.getIndex:** Still $O(N)$. Fine for current tests, but could be a future bottleneck if used in a hot loop (like `Solver.init`).
- **Prng Seeding:** Currently uses a constant seed (`42`) for stability in tests; real-world usage should use a high-entropy seed.

## Next Steps

1.  **Subgame Decomposition (Late Solving):** Implement a "Subgame Manager" that can solve the Flop using estimated leaf values and then trigger Turn/River solves on demand.
2.  **Leaf Value Estimation:** Implement a "Cheap Evaluator" (e.g., Equity-based) to provide values for Flop leaf nodes without full River enumeration.
3.  **Parallelization:** Utilize Zig's threading model to parallelize the sampled `walk` iterations or the independent runouts in `bestResponse`.
4.  **CLI/UI:** Create a way for users to input ranges/boards and view the resulting strategy.
