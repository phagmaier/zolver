# Poker

A heads-up postflop Texas Hold'em solver written from scratch in Zig 0.16.

The goal is to build a free local solver for laptops and desktops. It targets a practical, understandable engine that can solve flop, turn, and river spots with high accuracy and high performance through modern algorithmic and architectural optimizations.

## Status

The project has transitioned from a library-only engine to a functional toolchain:

- **Interactive TUI**: A terminal-based GUI (`poker tui`) for editing solve specs and viewing strategies.
- **Robust CLI**: Full support for one-shot solves (`poker solve`) and subgame resolving (`poker resolve`).
- **Standard Range Parser**: Supports PokerStove-style text ranges (e.g., `JJ+, AKs, 87s-54s`).
- **Production-Grade Solver**: Implementation of the **DCFR** algorithm (Brown & Sandholm 2019).
- **Out of Scope**: Preflop solving is not planned; the engine consumes preflop ranges as input.

## Features

- **DCFR Algorithm**: Discounted Counterfactual Regret Minimization for fast convergence.
- **SIMD Vectorization**: Inner per-hand loops vectorized via Zig's `@Vector` (AVX2/NEON ready).
- **Parallel Pool**: Persistent worker pool with atomic synchronization (no mutex overhead in hot paths).
- **Inclusion-Exclusion Terminals**: O(N + 52) showdown/fold evaluation, replacing O(N²) collision loops.
- **Subgame Decomposition**: Solve truncated flop trees and resolve turn/river cards as fresh subgames.
- **ZON Solve Specs**: Human-readable ZON files for declaring boards, ranges, and betting paths.
- **CSV Export**: Strategy export at the root for external analysis.

## Build Requirements

- Zig 0.16.0 or newer compatible 0.16 release.
- External Dependencies: [libvaxis](https://github.com/rockorager/libvaxis) (bundled via `build.zig.zon`).

## Build And Test

```bash
# Debug build
zig build

# Run all tests (checks for leaks and correctness)
zig build test

# Release build (recommended for solving)
zig build -Doptimize=ReleaseFast

# Run benchmark
zig build -Doptimize=ReleaseFast bench
```

### Running the Solver

**Interactive TUI:**
```bash
./zig-out/bin/Poker tui [examples/turn.zon]
```

**CLI Solve:**
```bash
./zig-out/bin/Poker solve --board AhKsQd --pot 50 --stack 200 --p1 "JJ+, AKs" --p2 "TT+, AQs+" --iters 100
```

## Project Layout

```text
src/card.zig          Compact card representation and deck logic
src/evaluator.zig     High-perf rank-histogram hand evaluator
src/range.zig         Dense range storage and hand tables
src/range_parser.zig  PokerStove-style text -> Range parser
src/gamestate.zig     Betting state machine and transitions
src/node.zig          Betting tree nodes and builders
src/cfr.zig           DCFR solver core with SIMD inner loops
src/subgame.zig       Subgame decomposition orchestration
src/spec.zig          ZON spec file types and path parsing
src/export.zig        CSV writer for strategy data
src/tui.zig           libvaxis-backed interactive solver UI
src/main.zig          CLI entry points (solve / resolve / tui)
src/root.zig          Module aggregator and test collector
```

## Solver Design

The engine uses **DCFR** (α=1.5, β=0, γ=2) for strategy optimization. Strategy averaging uses linear weighting, and regret storage is signed to allow for effective negative regret discounting.

For performance, the solver employs:
1. **Chance Sampling**: Public cards are sampled during training walks to keep iteration times low.
2. **Atomic Pool**: A persistent worker pool uses atomic `epoch` counters for zero-cost dispatch and join.
3. **Action-Major Layout**: Strategy and regret vectors are stored action-major to ensure SIMD hand-loops never stride.
4. **IE Terminals**: Terminal node evaluation uses card-bucketed accumulators to handle hand collisions in linear time.

## Roadmap

1. **Flexible Betting Trees**: Move from hardcoded `b50/b100` sizes to configurable per-street bet abstractions.
2. **Asynchronous Solving in TUI**: Move the CFR worker to a background thread to prevent UI freezing.
3. **Preflop Pipeline**: Support feeding pre-computed or standard preflop ranges into the TUI.
4. **Tree Navigation**: Add a way to navigate and view strategy for any node in the tree within the TUI.
5. **Memory Compression**: Implement i16/u16 compression for regrets and strategies to solve larger trees.

## License

No license file has been added yet.
