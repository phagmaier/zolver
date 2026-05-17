# AGENTS.md
file for tracking state direction and goals of the current project

## Project

A heads-up postflop solver for Texas Hold'em, written from scratch in Zig 0.16 (the latest stable). The goal is to solve flop/turn/river — preflop is out of scope; users will eventually upload their own preflop ranges.

This is not meant to compete with high-end commercial solvers. It is free software intended to run locally on laptops and desktops. We squeeze what performance we can, but the bar is "good and accurate on a personal machine," not "industrial."

## Build & Test

- **Debug build** (catches memory leaks and runs safety checks — use this by default): `zig build`
- **Release build**: `zig build -Doptimize=ReleaseFast`
- **Run all tests**: `zig build test`. Note: in Zig 0.16, `@import` alone doesn't pull a module's tests into the runner — `src/root.zig` ends with a `test { _ = mod; }` block that explicitly references every module so its `test` blocks get collected. **New `.zig` files must be added both as a `pub const X = @import(...)` *and* referenced in that test block**, or their tests will silently report `All 0 tests passed`.
- **Random seeding**: `solve()` takes a `std.Random` from the caller — pass a `std.Random.DefaultPrng.init(42).random()` from tests for determinism. For production entropy on Zig 0.16, use the `std.Io` random APIs rather than the removed `std.crypto.random` convenience.
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
Instead of enumerating all possible public runouts at every iteration, the solver samples **one** public card per chance-node visit in `walk`.
- **Logic:** In `walk`, if `is_chance` is true, a random legal card is sampled and added to the board. `reinitForBoard` updates the solver state, and recursion continues.
- **Card Removal:** When a runout is sampled, both players' reach vectors are masked to zero on hands containing the new board card *before* recursing, so downstream regret / strategy_sum updates don't accumulate mass for hands that are illegal on the new board.
- **Per-Hand Chance Conditioning:** Public samples are drawn from cards not on the board, then each private hand is importance-corrected by its own blocker-conditioned chance denominator. Exact chance enumeration in `brWalk` and `allInEquityLeaf` uses the same per-hand denominators: a turn-chance river has 46 legal cards for an unblocked private hand; a flop-chance ordered turn-river runout has 47×46 legal ordered pairs.
- **Best Response:** `bestResponse` and `exploitability` still use **full enumeration** of runouts for exactness. Since these are called infrequently, the $O(\text{runouts})$ cost is acceptable for the precision gain.

#### Strategy Extraction
`averageStrategy(node, out)` normalizes a non-chance node's `strategy_sum` into per-action probabilities per hand, laid out as `out[action * NUM_HANDS + hand_idx]`. This is the public-facing readout from a solved tree (used by the upcoming CLI and by any leaf-evaluator that wants to plug into a parent solve). Hands with zero accumulated mass fall back to uniform.

#### All-In Equity Leaf Evaluator (Subgame Decomposition Phase 1)
`allInEquityLeaf(edge, p1_reach, p2_reach, out_cfv_p1, out_cfv_p2)` is the cheap leaf value used when a truncated tree stops descending at a chance node. It assumes both players shove their remaining stacks immediately: synthetic showdown pot = `edge.amount + 2 * min(edge.stack1, edge.stack2)`, with `computeShowdownCFV` called per runout at `half_pot = effective_pot / 2` (same winner-gains-half-pot convention as `terminalShowdown`). Enumerates the remaining board completions; a complete board takes the trivial single-showdown path. Reach masking and per-hand chance averaging mirror `brWalk`'s chance handler so values are consistent with full-tree CFVs. Verified by tests covering the full-board path, flop and turn chance entries, and exact private-blocker chance denominators.

#### Truncated Tree Builder (Subgame Decomposition Phase 2)
`node.buildTreeTruncated(..., truncate_after: Street)` now stops at the configured street boundary by emitting a chance node with `is_chance = true` and `is_leaf = true`. The leaf stores one synthetic `Action.CHANCE` edge carrying the current pot and stack state; `walk` and `brWalk` detect the leaf and call `allInEquityLeaf` directly instead of descending into later-street betting. This is the v1 truncation boundary for flop-to-turn and turn-to-river subgame decomposition.

### Game Tree

The betting tree lives in `src/gamestate.zig` (state machine) and `src/node.zig` (tree structure).

- **Chance Nodes:** Street transitions produce a `Node` with `is_chance = true`. Normal chance nodes have exactly one outgoing edge tagged `Action.CHANCE`; truncated chance leaves additionally set `is_leaf = true` and terminate through the all-in equity evaluator.
- **Pre-River All-in Runouts:** A call of an all-in pre-river is *not* terminal. `getCallGameState` marks it as a chance state, and `applyChance` chains additional chance steps (one per pending street) until the river is dealt — at which point the post-chance state is `isTerm = true`. This produces a chain like `(call edge) → chance(turn) → chance(river) → terminal showdown` for a FLOP all-in. The chance-terminal showdown is handled inside `walk` / `brWalk` by calling `terminalShowdown` on the chance edge whose child is `null`. CS-CFR samples one runout per chain visit during `walk`; `brWalk` enumerates fully for exactness.
- **Subgame Decomposition:** The solver can traverse any street, build truncated trees that stop at a configured chance boundary, and use all-in equity leaves. `SubgameManager` now adds the orchestration layer for solving a Flop once, collecting chance seeds, and spinning up fresh Turn/River re-solves.

### Subgame Manager (src/subgame.zig)

`Subgame` owns a fresh CFR instance, arena-backed tree, root `GameState`, board, root reach vectors, and last CFV buffers. It is the reusable "GameState + ReachProbs → fresh solver" wrapper. `Subgame.init(..., .{ .truncate_after = .FLOP/.TURN })` builds a truncated tree; passing default options builds a full street tree.

`SubgameManager` currently owns one cached truncated Flop solution plus its first chance-boundary seeds. `solveFlop` builds/solves a Flop tree truncated at Turn and then walks average strategies to collect `ChanceSeed` entries. Each seed carries a fixed-size action path, so callers can use `findSeedByPath(&.{ .CHECK, .CHECK })` / `solveTurnByPath(...)` instead of relying on array order. `solveTurn(seed_index, turn_card, ...)` masks private hands containing that public Turn card, applies the chance transition, and spins up a fresh Turn `Subgame` truncated at River. `solveRiverFromSeed` is the generic helper for resolving a River subgame from a Turn chance seed.

## Current State

- **Performance:** `zig build test` took ~66s after the Phase 4 verification tests were added. Turn-start solves converge in seconds; tests that enumerate all-in leaf runouts or exact exploitability are the main runtime cost.
- **Verification:** Convergence is verified on AA-vs-KK toy games (River and Turn) and a "Polarized vs Condensed" range test, with exploitability asserted `< 0.05` after 200 CFR+ iterations. Behavioral correctness is checked by asserting KK folds to a bet on the AA-vs-KK river via `averageStrategy`. Tree structure for pre-river all-in runouts and truncated chance leaves is verified by `node.zig` structural tests. Snapshot/restore round-trip is verified directly. Chance enumeration is checked for private-hand blocker denominators in both `allInEquityLeaf` and `brWalk`, and the walker leaf path is tested directly. `subgame.zig` verifies fresh solver construction from dense reaches, Flop chance-seed collection, Turn re-solver construction, Turn full-vs-truncated all-in response consistency, bounded compact truncated polarized/condensed exploitability, and truncated Flop tree-size reduction. `cfr.zig` verifies that the all-in equity leaf matches exact full-runout chance enumeration on AA-vs-KK.
- **Correctness:** All 45 tests pass with `zig build test`.

## Known Gaps & Cautions

- **Memory Scaling:** While fast, a full Flop tree with all runouts stored would be very large. **Subgame Decomposition** is required to solve Flops with limited RAM.
- **HandTable.getIndex:** Still $O(N)$. Fine for current tests, but could be a future bottleneck if used in a hot loop (like `Solver.init`).
- **Walk Stack Footprint:** `walk` allocates large per-call buffers on the stack (`strategy`, `child_cfv_p1/p2`, `new_p1/p2_reach`), plus ~18 KB of `BoardSnapshot` on the chance branch. `MAX_ACTIONS` is now the real max of 5, but heap-backed scratch buffers are still likely cleaner before parallel worker stacks are introduced.
- **Street Conventions:** `Street.FLOP/TURN/RIVER` is interpreted by `walk` as "decisions on a board with 3/4/5 cards revealed respectively"; chance nodes deal one card per street transition. Tests now follow that convention; new test setups should keep street and board-card count aligned.

## Roadmap

Priority order, engine first, user-facing last:

1.  **Parallelization** — Zig threading on the sampled `walk` iterations or the independent runouts in `bestResponse`. `reinitForBoard` mutates solver-wide state, so parallel chance enumeration needs thread-local strength/sort buffers or a per-worker context. The existing `BoardSnapshot` is a natural unit for that.
2.  **Accuracy tuning / leaf models** — Phase 4 has basic bounds, but full-topology truncated exploitability is still expensive to run as a unit test. Future work can add slower benchmarks and compare all-in equity against a check-down or learned leaf model.
3.  **Small cleanups when convenient:** make `HandTable.getIndex` non-linear if it ever lands in a hot loop, consider heap-backed scratch buffers for `walk`/`brWalk`, and decide whether same-action paths with different bet sizes need richer public seed labels.
4.  **CLI/UI (last):** Parse user-supplied ranges/boards, run a solve, print per-action probabilities via `averageStrategy`. Range input format: investigate whether a community standard exists (PioSOLVER text format, GTO+ JSON, etc.) before defining our own. Otherwise spec a minimal format. Also support file upload of a preflop range.

## Plan: Subgame Decomposition (current major track)

### Why

A full Flop tree with all turn × river runouts enumerated blows up memory:
- Per chance node: 47 turn cards × 46 river cards = 2,162 distinct boards.
- Per board: a full betting subtree with regret + strategy_sum vectors of size `edges × 1326`.
- Even at 100 bytes per node and a modest action set, a single Flop solve is multiple GB.

Modern free solvers solve this by **truncating** the Flop tree at the turn chance node and replacing the missing subtree with an **approximate per-hand value** from a cheap "leaf evaluator." After the Flop converges, individual **Turn** and **River** subgames can be re-solved on demand, anchored to the Flop's reach distribution at the chance node. The Turn re-solve in turn truncates at the river chance and uses the leaf evaluator there. This keeps the working set to a single street at a time.

### Goal

Make Flop solving fit in laptop RAM with accuracy that is competitive for personal-machine use (not industrial), and expose an API where a user can say "give me the strategy on Turn = T♣" without ever materializing the full game tree.

### Phase 1 — All-In Equity Leaf Evaluator ✅ Done

Lives in `cfr.zig` as `Solver.allInEquityLeaf`. See the "All-In Equity Leaf Evaluator" subsection under **CFR Solver** above for the as-built description; the original design notes below are preserved for context.

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

### Phase 2 — Truncated Tree Builder ✅ Done

Implemented in `src/node.zig` as a sibling builder that stops descending when crossing a configured street boundary:

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

When the builder would emit a chance node that crosses past `truncate_after`, it emits a **leaf chance node** with `is_chance = true`, `is_leaf = true`, and one synthetic `Action.CHANCE` edge carrying the current pot/stacks. Walkers detect this and call `allInEquityLeaf` instead of sampling/enumerating or descending to later-street betting.

**`walk` change:** when `node.is_chance and node.is_leaf`, call the leaf evaluator with the current `p1_reach` / `p2_reach`, write directly to `out_cfv_*`, return. No descent, no `reinitForBoard` in the walker branch because the leaf evaluator handles its own enumeration.

**`brWalk` change:** symmetric. Leaf is a hard boundary for BR enumeration too.

**Test:**
- `node.zig` verifies that a flop check-check transition becomes a leaf chance node with one terminal `Action.CHANCE` edge.
- `cfr.zig` verifies that `walk` dispatches a truncated chance leaf to `allInEquityLeaf`.

### Phase 3 — SubgameManager (composition) ✅ Done

Implemented in `src/subgame.zig` as a small owner/wrapper around fresh CFR instances:

```zig
pub const SubgameManager = struct {
    flop: ?Subgame,                         // truncated at turn
    chance_seeds: std.ArrayList(ChanceSeed),

    pub fn solveFlop(..., iters: usize, random: std.Random) !void;
    pub fn solveTurn(self: *SubgameManager, seed_index: usize, turn_card: Card, iters: usize, random: std.Random) !Subgame;
};

pub fn solveRiverFromSeed(..., seed: *const ChanceSeed, turn_board: [5]Card, river_card: Card, ...) !Subgame;
```

`Subgame.init` is the lower-level re-solver API: it takes a `GameState`, board, dense `ReachProbs`, and optional truncation boundary, then builds a fresh tree and `Solver`.

**Reach propagation:** the manager walks the solved Flop tree using `averageStrategy` and records first chance-boundary `ChanceSeed`s. A seed stores the chance `GameState` and dense reaches at that point. Resolving a public Turn/River masks hands containing the dealt card before building the child subgame.

**Turn subgame solve:** `solveTurn` uses the selected Flop seed, fills the Turn card, applies the chance transition to get a Turn root state, builds a fresh Turn tree truncated at River, then solves with CFR+.

**River subgame solve:** use `Subgame.collectChanceSeeds` on a solved Turn `Subgame`, then pass the selected seed to `solveRiverFromSeed`; the River tree is full because no later street remains.

### Phase 4 — Verification ✅ Done

Basic fast-running bounds are in place. Cheap leaf evaluators still introduce model error, so deeper accuracy characterization should live in benchmark-style tests rather than the normal unit suite.

**Tests:**
1. **Equity oracle on AA-vs-KK:** `cfr.zig` compares `allInEquityLeaf` against exact full turn+river chance enumeration for AA-vs-KK after an all-in call; values match to `1e-3`.
2. **Turn re-solve consistency:** `subgame.zig` solves a full Turn subgame and a Flop-seeded truncated Turn re-solve on the same AA-vs-KK line, then compares KK's facing-all-in fold/call strategy within a broad tolerance.
3. **Polarized vs condensed truncated:** a compact truncated game using polarized/condensed ranges asserts bounded exploitability after CFR+. The full betting topology was too slow for a default unit test.
4. **Memory test:** `subgame.zig` counts full vs truncated Flop tree edges with tiny regret-vector allocations and asserts the truncated topology is smaller and below a fixed threshold.

### Decisions Made

- **Node flag vs new type:** `is_leaf: bool` on the existing `Node` is the v1 choice. It keeps tree plumbing simple and is covered by structural tests.
- **Leaf model choice:** all-in equity (Phase 1) vs "check-down" equity (assume both players check the rest of the way). All-in is more common in literature and produces a more aggressive game tree; check-down is more conservative. Start with all-in, leave the model as a parameter so check-down can be added later.
- **Reach propagation precision:** with linear-weighted averaging, the "average strategy" is *time-averaged*, not the instantaneous best response. Propagated reaches should use this averaged strategy, not the current iteration's. The existing `averageStrategy` API gives the right object.
- **Caching across runs:** if `solveTurn` is called many times for different turn cards from the same Flop solution, the Flop work is done once and the per-turn cost is just the (smaller) turn solve. That's the whole point of the architecture. Make sure the Flop solver state is preserved across Turn calls.
- **Street convention cleanup:** done. Tests should maintain "`Street.X` ⟺ X cards on the board."

### Files Likely to Change Next

- `src/subgame.zig` — richer chance-seed labels if action paths alone become ambiguous for CLI callers.
- `src/cfr.zig` / `src/node.zig` — possible API adjustments for slower benchmark tooling or lower-level strategy hooks.
- `AGENTS.md` — update Current State and Roadmap after each large implementation.

### Estimated Effort

- Phase 1 (leaf evaluator): done.
- Phase 2 (truncated tree): done.
- Phase 3 (SubgameManager): done.
- Phase 4 (verification + bounds): done for fast unit coverage; deeper accuracy tuning remains future benchmark work.
