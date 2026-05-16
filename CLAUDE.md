# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

A heads-up postflop solver for Texas Hold'em, written from scratch in Zig 0.16 (the latest stable). The goal is to solve flop/turn/river — preflop is out of scope; users will eventually upload their own preflop ranges.

This is not meant to compete with high-end commercial solvers. It is free software intended to run locally on laptops and desktops. We squeeze what performance we can, but the bar is "good and accurate on a personal machine," not "industrial."

## Build & Test

- **Debug build** (catches memory leaks and runs safety checks — use this by default): `zig build`
- **Release build**: `zig build -Doptimize=ReleaseFast`
- **Run all tests**: `zig build test` — runs every `test` block reachable from `src/root.zig` and `src/main.zig`. New test files should be added to `src/root.zig` so they get picked up.
- **Run tests in a single file**: `zig test src/<file>.zig`

## Architecture

### PokerEval (evaluator.zig)

Hand evaluation lives in the `PokerEval` dependency (see `build.zig.zon`). Assume it is correct and fast — it returns a strength score given seven `Card`s. `main.zig` has an example.

#### Card encoding (card.zig)

A `Card` packs four representations of one card so the evaluator can pick whichever is cheapest per check:

- **bits 0–7** — prime number for the rank (Two=2 … Ace=41, from `PRIMES`). The new evaluator no longer uses this field; it is kept for backwards-compatibility with any consumer that wants to do prime-product math.
- **bits 8–11** — rank index 0–12. Used for the rank-histogram path.
- **bits 12–15** — suit as a one-hot nibble (`SPADE=1, HEART=2, DIAMOND=4, CLUB=8`). The evaluator does `@ctz(nibble)` to get a 0–3 suit index.
- **bits 16–28** — one-hot rank pattern bit. Unused in the current hot path; kept available for future SIMD work.

`makeCard(rank, suit)` takes `rank` as 0–12 and `suit` as 0–3 (NOT the one-hot nibble — it shifts `1 << suit` internally to produce the nibble).

### Game tree (WIP)

The betting tree lives in `src/gamestate.zig` (state machine) and `src/node.zig` (tree of `Node`s and `Edge`s built recursively from a root state).

- `GameState` is an immutable-ish value: every `get*GameState` method returns a fresh `GameState` (or `null` if the action is illegal). Methods take `*const GameState` since they only read.
- `buildTree` enumerates every reachable state from a root, populating a `Node` per decision point with empty `regrets` / `strategy_sum` slices sized `edges.len * numCards` — ready for CFR to fill in.
- Bet sizes are hardcoded in `BETSIZES` (`0.5x` and `1.0x` pot). Eventually this should be per-street / per-spot.
- `MAXNUMBETS = 2`: bet + raise allowed per street, no reraising the reraise. All-in is always allowed regardless of `numbets` and counts as terminal action sequence-wise.

#### Chance nodes

Street-advancing transitions (check-check, non-allin bet-call on flop/turn) produce a **chance state** — `is_chance = true` on `GameState`, street not yet advanced. `applyChance()` consumes a chance state and returns the post-deal decision state with the street bumped.

In the tree (`node.zig`), every chance state becomes a `Node` with `is_chance = true` and exactly one outgoing edge tagged `Action.CHANCE`. Chance nodes do not allocate `regrets` / `strategy_sum` — they have no strategic decision to make.

CFR enumerates runouts when it reaches a chance node: loop over the remaining unblocked cards, recurse into the single child subtree per card, and apply card-removal weighting per hand. The betting subtree below a chance node is shared across runouts in structure but strategy data must be stored per-runout. For memory, plan on subgame decomposition (solve flop with cheap turn/river leaf values, then re-solve each turn / river subgame independently) rather than holding all runouts' strategies simultaneously.

#### Conventions

- `isp1` tracks whose turn it currently is. On a new street, `nextStreet()` resets it to `true`, so player 1 is always the OOP / first-to-act on flop, turn, and river. Caller must seed the initial `isp1` accordingly.
- `pot + stack1 + stack2` is invariant across every state transition — the `chipsConserved` test helper verifies this.
