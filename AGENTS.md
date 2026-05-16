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

## Roadmap

Priority order, engine first, user-facing last:

1.  **Subgame Decomposition + Leaf Value Estimation** — the next major piece. Full plan in the next section.
2.  **Parallelization** — Zig threading on the sampled `walk` iterations or the independent runouts in `bestResponse`. `reinitForBoard` mutates solver-wide state, so parallel chance enumeration needs thread-local strength/sort buffers or a per-worker context. The existing `BoardSnapshot` is a natural unit for that.
3.  **Small cleanups when convenient:** drop `MAX_ACTIONS` from 6 → 5 (real max), make `HandTable.getIndex` non-linear if it ever lands in a hot loop, fix the turn-start CFR test's 3-card-on-`Street.TURN` mismatch to pin the street convention.
4.  **CLI/UI (last):** Parse user-supplied ranges/boards, run a solve, print per-action probabilities via `averageStrategy`. Range input format: investigate whether a community standard exists (PioSOLVER text format, GTO+ JSON, etc.) before defining our own. Otherwise spec a minimal format. Also support file upload of a preflop range.

## Plan: Subgame Decomposition (next major piece)

### Why

A full Flop tree with all turn × river runouts enumerated blows up memory:
- Per chance node: 47 turn cards × 46 river cards = 2,162 distinct boards.
- Per board: a full betting subtree with regret + strategy_sum vectors of size `edges × 1326`.
- Even at 100 bytes per node and a modest action set, a single Flop solve is multiple GB.

Modern free solvers solve this by **truncating** the Flop tree at the turn chance node and replacing the missing subtree with an **approximate per-hand value** from a cheap "leaf evaluator." After the Flop converges, individual **Turn** and **River** subgames can be re-solved on demand, anchored to the Flop's reach distribution at the chance node. The Turn re-solve in turn truncates at the river chance and uses the leaf evaluator there. This keeps the working set to a single street at a time.

### Goal

Make Flop solving fit in laptop RAM with accuracy that is competitive for personal-machine use (not industrial), and expose an API where a user can say "give me the strategy on Turn = T♣" without ever materializing the full game tree.

### Phase 1 — All-In Equity Leaf Evaluator

Build a function that, at a chance node, returns the per-hand CFV under the simplifying assumption that **both players commit their remaining stacks immediately** and the rest of the board runs out.

Why this assumption: it's the most common cheap leaf model in the literature. It overestimates pot size somewhat (real players don't always shove) but is the standard v1.

**API sketch (lives in `cfr.zig`):**
```zig
pub fn allInEquityLeaf(
    self: *Solver,
    edge: *const Edge,           // for pot + stacks
    p1_reach: []const f32,
    p2_reach: []const f32,
    out_cfv_p1: []f32,
    out_cfv_p2: []f32,
) void
```

**Mechanics:**
- The effective pot at the leaf = `edge.pot + min(p1_remaining, p2_remaining)` (caller's remaining stacks).
- Half-pot per player on a win; per-hand EV is `equity × half_pot - (1 - equity) × half_pot`.
- Enumerate remaining board cards (1 or 2 depending on current street). For each runout, call `reinitForBoard` and use the existing `terminalShowdown` machinery — that already does O(N) per-hand EV given the showdown environment. Average across runouts.
- Use a `BoardSnapshot` to restore state cheaply after the enumeration (parity with `brWalk`'s chance handler).

**Test:**
- AA-vs-KK on a dry flop should give AA ≈ 80–85% equity (over all turn + river runouts). Assert per-hand CFV consistent with that equity × pot.
- Symmetric ranges should sum to ~0 CFV.

### Phase 2 — Truncated Tree Builder

Add a flag (or a sibling builder) that stops descending when crossing a configured street boundary:

```zig
pub fn buildTreeTruncated(
    state: *GameState,
    arr: *std.ArrayList(Edge),
    arena: Allocator,
    temp_allocator: Allocator,
    numCards1: u16, numCards2: u16,
    truncate_after: Street,   // e.g., .FLOP → no turn/river decisions
) !void
```

When the builder would emit a chance node that crosses past `truncate_after`, instead emit a **leaf chance node**: `Node { is_chance: true, is_leaf: true, edges: [] }` (or just a flag on the existing Node — see Open Questions). Walkers detect this and call `allInEquityLeaf` instead of sampling/enumerating.

**`walk` change:** when `node.is_chance and node.is_leaf` (or whatever the marker becomes), call the leaf evaluator with the current `p1_reach` / `p2_reach`, write directly to `out_cfv_*`, return. No descent, no `reinitForBoard` (because the leaf evaluator handles its own enumeration).

**`brWalk` change:** symmetric. Leaf is a hard boundary for BR enumeration too.

**Test:**
- Truncated Flop tree node count should be a small constant × the betting tree size, *not* multiplied by 47 × 46.
- Build and walk a truncated Flop tree on AA-vs-KK; verify it converges and the CFV at root is within tolerance of the equity-based prediction (≈ AA's all-in equity × root pot).

### Phase 3 — SubgameManager (composition)

A new module / type that orchestrates "solve flop now, solve turn-on-demand, solve river-on-demand":

```zig
pub const SubgameManager = struct {
    flop_solver: Solver,        // truncated at turn
    flop_root:   *Node,
    // ... arena/allocators ...

    pub fn solveFlop(self: *SubgameManager, iters: usize, random: std.Random) void;

    // Build + solve a turn subgame on a specific turn card.
    // Uses the flop's converged strategies to derive reach at the chance node.
    pub fn solveTurn(self: *SubgameManager, turn_card: Card, iters: usize, random: std.Random) !TurnSolution;

    pub fn solveRiver(self: *SubgameManager, turn_card: Card, river_card: Card, iters: usize, random: std.Random) !RiverSolution;
};
```

**Reach propagation:** to seed the Turn subgame, walk the flop tree with `averageStrategy` to compute the reach vectors at each (flop) chance node. The Turn root's reach = (chance-node reach) with hands containing the dealt turn card zeroed out. This is a tree-walk pass over the converged solution, not a re-solve — cheap.

**Turn subgame solve:** a fresh `Solver` instance, rooted at the dealt turn board, truncated at river. Use the propagated reaches as `p1_reach` / `p2_reach`. Solve with CFR+ as today.

**River subgame solve:** identical pattern, no truncation needed (river has no further streets), uses the turn solution's chance-node reach.

### Phase 4 — Verification

The hard part. Cheap leaf evaluators introduce error. We need to bound how bad the approximation is.

**Tests:**
1. **Equity oracle on AA-vs-KK:** A full-tree solve and a truncated-tree solve should agree on root CFV to within ~5% on a heads-up all-in-only game.
2. **Turn re-solve consistency:** Solve the full game (turn-start, no truncation) and a truncated flop + Turn re-solve, on the *same* game. Strategies at the turn-decision node should be close.
3. **Polarized vs condensed truncated:** Run the existing polarized/condensed test in truncated form; exploitability won't hit `< 0.05` (the leaf approximation introduces a floor) but should remain bounded.
4. **Memory test:** Assert the truncated flop tree's total `Edge` count is below some threshold (sanity check that truncation actually trimmed it).

### Open Questions / Decisions to Make in Implementation

- **Node flag vs new type:** is `is_leaf: bool` enough on the existing `Node`, or do we need a dedicated `LeafNode` variant? The flag is simpler; the variant is type-safe. Lean flag for v1.
- **Leaf model choice:** all-in equity (Phase 1) vs "check-down" equity (assume both players check the rest of the way). All-in is more common in literature and produces a more aggressive game tree; check-down is more conservative. Start with all-in, leave the model as a parameter so check-down can be added later.
- **Reach propagation precision:** with linear-weighted averaging, the "average strategy" is *time-averaged*, not the instantaneous best response. Propagated reaches should use this averaged strategy, not the current iteration's. The existing `averageStrategy` API gives the right object.
- **Caching across runs:** if `solveTurn` is called many times for different turn cards from the same Flop solution, the Flop work is done once and the per-turn cost is just the (smaller) turn solve. That's the whole point of the architecture. Make sure the Flop solver state is preserved across Turn calls.
- **Street convention cleanup:** before this work, lock the convention "`Street.X` ⟺ X cards on the board." Fix the turn-start CFR test (currently 3 cards on `Street.TURN`). This is a small precondition.

### Files Likely to Change

- `src/cfr.zig` — add `allInEquityLeaf`, leaf-handling branches in `walk` / `brWalk`. Possibly factor out the per-runout enumeration loop that's already in `brWalk` so the leaf evaluator can reuse it.
- `src/node.zig` — add `is_leaf` flag to `Node`; add `buildTreeTruncated` (or a `truncate_after: ?Street` param to `buildTree`).
- `src/subgame.zig` (new) — `SubgameManager` and reach propagation.
- `src/root.zig` — register the new module + reference in the `test {}` block (otherwise its tests won't run, per the gotcha at the top of this doc).
- `AGENTS.md` — update Architecture with a "Subgame Decomposition" subsection once it's in.

### Estimated Effort

- Phase 1 (leaf evaluator): ~half a session — small, well-defined, lots of code reuse from `brWalk`.
- Phase 2 (truncated tree): ~half a session — straightforward flag plumbing once Phase 1 is in.
- Phase 3 (SubgameManager): ~one session — most of the new design lives here.
- Phase 4 (verification + bounds): ~one session — easy to underestimate; budget time for tuning leaf models if accuracy is bad.
