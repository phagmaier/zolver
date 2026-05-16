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

Hand evaluation lives in the `PokerEval` dependency (see `build.zig.zon`). Assume it is correct and fast — it returns a strength score given seven `Card`s. `main.zig` has an example.

#### Card encoding (card.zig)

A `Card` packs four representations of one card so the evaluator can pick whichever is cheapest per check:

- **bits 0–7** — prime number for the rank (Two=2 … Ace=41, from `PRIMES`). The new evaluator no longer uses this field; it is kept for backwards-compatibility with any consumer that wants to do prime-product math.
- **bits 8–11** — rank index 0–12. Used for the rank-histogram path.
- **bits 12–15** — suit as a one-hot nibble (`SPADE=1, HEART=2, DIAMOND=4, CLUB=8`). The evaluator does `@ctz(nibble)` to get a 0–3 suit index.
- **bits 16–28** — one-hot rank pattern bit. Unused in the current hot path; kept available for future SIMD work.

`makeCard(rank, suit)` takes `rank` as 0–12 and `suit` as 0–3 (NOT the one-hot nibble — it shifts `1 << suit` internally to produce the nibble).

### Game tree

The betting tree lives in `src/gamestate.zig` (state machine) and `src/node.zig` (tree of `Node`s and `Edge`s built recursively from a root state).

- `GameState` is an immutable-ish value: every `get*GameState` method returns a fresh `GameState` (or `null` if the action is illegal). Methods take `*const GameState` since they only read.
- `buildTree` enumerates every reachable state from a root, populating a `Node` per decision point with empty `regrets` / `strategy_sum` slices sized `edges.len * numCards` — ready for CFR to fill in.
- Bet sizes are hardcoded in `BETSIZES` (`0.5x` and `1.0x` pot). Eventually this should be per-street / per-spot.
- `MAXNUMBETS = 2`: bet + raise allowed per street, no reraising the reraise. All-in is always allowed regardless of `numbets` and counts as terminal action sequence-wise.

#### Node / Edge data CFR depends on

- **`Node.isp1: bool`** — whose decision this node represents. CFR reads it to pick which player's `regrets` / `strategy_sum` slice to touch and which player's reach to scale by the current strategy.
- **`Edge.stack1 / stack2: f32`** — stacks captured at the time the edge's action was taken. At a terminal, the solver recovers each side's contribution since solver root as `initial_stack - edge.stack`. `Edge.amount` is still the pot at that point.
- Chance nodes have `is_chance = true` and `isp1` is meaningless on them (set but unused).

#### Chance nodes

Street-advancing transitions (check-check, non-allin bet-call on flop/turn) produce a **chance state** — `is_chance = true` on `GameState`, street not yet advanced. `applyChance()` consumes a chance state and returns the post-deal decision state with the street bumped.

In the tree (`node.zig`), every chance state becomes a `Node` with `is_chance = true` and exactly one outgoing edge tagged `Action.CHANCE`. Chance nodes do not allocate `regrets` / `strategy_sum` — they have no strategic decision to make.

CFR enumerates runouts when it reaches a chance node: loop over the remaining unblocked cards, recurse into the single child subtree per card, and apply card-removal weighting per hand. The betting subtree below a chance node is shared across runouts in structure but strategy data must be stored per-runout. For memory, plan on subgame decomposition (solve flop with cheap turn/river leaf values, then re-solve each turn / river subgame independently) rather than holding all runouts' strategies simultaneously.

#### Conventions

- `isp1` tracks whose turn it currently is. On a new street, `nextStreet()` resets it to `true`, so player 1 is always the OOP / first-to-act on flop, turn, and river. Caller must seed the initial `isp1` accordingly.
- `pot + stack1 + stack2` is invariant across every state transition — the `chipsConserved` test helper verifies this.

### CFR solver (`src/cfr.zig`)

River-only vector-CFR solver. State:

- `Solver` holds the static showdown environment (precomputed `hand_strengths[1326]`, `blocked` mask), the root baseline (`initial_stack1/2`, `pot_at_root`), and the dense reach vectors `p1_reach[1326]`, `p2_reach[1326]`. The caller's sparse `Range` is scattered into the dense vectors at `init` and blocked entries are zeroed.
- **`solve(self, root, iterations, out_cfv_p1, out_cfv_p2)`** runs the vector-CFR walker for N iterations. Last-iteration root CFVs land in the out buffers.
- **`walk`** (file-scope) — recursive per-iteration pass. Per node: regret matching → strategy, recurse with the actor's reach scaled by their strategy, combine child CFVs (actor mixes; opponent sums straight because their scaling is in the children), then update the actor's `regrets` (`+= child_cfv − node_cfv`) and `strategy_sum` (`+= own_reach * sigma`).
- **`bestResponse(self, root, br_isp1, out_cfv)`** computes the best-response CFV vector for one player against the opponent's *average* strategy (normalized `strategy_sum`).
- **`exploitability(self, root) -> f32`** sums both BR values weighted by each player's reach. → 0 at NE; positive numbers measure how much can still be extracted.
- **Terminal payoffs** are per-hand CFVs (`= Σⱼ opp_reach[j] · 1[i,j compat] · payoff(i,j)`) with card-removal masking. `terminalFold` uses parent's `isp1` as folder identity; `terminalShowdown` uses precomputed `hand_strengths`.

#### Conventions / invariants

- **Sign convention**: all CFVs are signed in their own player's favor. `cfv_p1 + cfv_p2 = 0` (zero-sum) at every node.
- **Hand vectors are dense `[1326]f32`** inside the solver, indexed by `HandTable` order. Blocked hands carry reach 0 forever; the densify step at `init` is the only place that consults the sparse input `Range`.
- **`MAX_ACTIONS = 6`** — upper bound on a node's outgoing edges; stack-allocated scratch buffers in `walk` / `brWalk` size to this.
- **Method-call syntax doesn't reach file-scope functions.** `walk`, `brWalk`, `solve`, `bestResponse`, `exploitability` are at file scope (consistent style), so call them as `walk(self, ...)` rather than `self.walk(...)`. The `terminalFold` / `terminalShowdown` methods *are* inside the `Solver` struct, so `self.terminal*(...)` works for those.

#### Known gaps

- **Chance nodes panic** — the walker has `if (node.is_chance) unreachable;`. Fine for river-only; needs runout enumeration before turn/flop will work.
- **Pre-river all-in + call** is currently treated by the existing terminal code as immediate showdown using the fixed board, which is wrong (no runout). Tests don't exercise this; will be fixed alongside chance-node support.
- **`HandTable.getIndex` is O(N)** — linear search. Fine for tests, will need a perfect-hash or sort-based lookup if it ever ends up in a hot loop.

## Current state

- River-only vector CFR works end-to-end: `Solver.init` → `solve` → `exploitability`.
- Convergence is verified on the AA-vs-KK toy game: root `cfv_p1[AA] = 25.000` exactly (the NE value), exploitability `≈ 0.75` after 200 vanilla-CFR iterations.
- All 25 tests pass. Debug-mode `zig build test` takes ~57s, dominated by the AA-vs-KK 200-iter solve. Almost all of that time is in the `O(1326²)` terminal-payoff loops.

## Open options for next step

These are independent; any one is a reasonable next move:

1. **Performance pass on terminal payoffs.** The naive `O(N²)` showdown loop is the bottleneck. The standard fix is to sort hands by `hand_strengths`, then use a prefix-sum sweep to compute showdown CFV in `O(N)` per terminal (the card-removal correction is a second pass over the at-most-49 hands that share a card with each `i`). Same trick adapts to `terminalFold` for the compat-mass sums. Expected win: 1–2 orders of magnitude on the convergence test in Debug, more in Release.

2. **Real range vs range test.** The solver has only been exercised on single-hand-each ranges. Stand it up against e.g. a "value-heavy vs draw-heavy" matchup on a textured river and check that exploitability still trends → 0 and the average strategy looks sane (e.g. value hands bet, draws check). Will run slowly until (1) is done.

3. **Chance nodes / Step 7 (turn or flop).** Extend the walker to enumerate runouts at chance nodes. Per CLAUDE.md's chance-node section, the right shape is: at a chance node, loop over the 47 remaining unblocked cards, recompute the showdown table for the new board, recurse into the (one) child subtree, weight contributions by `1/47` plus card-removal. Memory pressure starts here — for flop, plan on subgame decomposition (cheap leaf values at flop, re-solve each turn / river subgame independently) rather than holding all runouts' strategy data at once.
