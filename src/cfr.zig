const std = @import("std");
const Allocator = std.mem.Allocator;
const card_mod = @import("card.zig");
const Card = card_mod.Card;
const range_mod = @import("range.zig");
const Range = range_mod.Range;
const HandTable = range_mod.HandTable;
const node_mod = @import("node.zig");
const Node = node_mod.Node;
const Edge = node_mod.Edge;
const gamestate_mod = @import("gamestate.zig");
const Evaluator = @import("evaluator.zig").Evaluator;

pub const NUM_HANDS: usize = 1326;
// Upper bound on simultaneous actions out of any node. Worst case is facing a
// bet: {fold, call, all-in, 2 raise sizes} = 5.
const MAX_ACTIONS: usize = 5;
// Upper bound on simultaneously-live chance snapshots in a single walk path.
// The deepest chance chain we ever traverse is a pre-river all-in: a flop
// chance saves once, recurses into a turn chance that saves once, recurses
// into a river chance that saves once → 3.
const MAX_CHANCE_DEPTH: usize = 3;

// Upper bound on workers spawned by the `brWalk` chance-runout parallel
// dispatch. Beyond ~8 workers the per-postflop tree gains diminish and
// cache-line contention on the shared `node.strategy_sum` reads starts to
// dominate, so we cap regardless of CPU count.
const MAX_PARALLEL_WORKERS: usize = 8;

// Per-iter wall-clock breakdown for the parallel `cfr.solve` path. `join_ns`
// dominates the walk-time budget — the main thread is blocked in
// `threads[j].join()` while workers run, so it captures max(walk_time) plus
// the join syscall itself.
pub const ParallelTimings = struct {
    iter_count: u64 = 0,
    spawn_ns: u64 = 0,
    join_ns: u64 = 0,
    merge_ns: u64 = 0,
};

fn timestampDeltaNs(from: std.Io.Clock.Timestamp, to: std.Io.Clock.Timestamp) u64 {
    const diff: i96 = to.raw.nanoseconds - from.raw.nanoseconds;
    if (diff < 0) return 0;
    return @intCast(diff);
}

// All board-derived solver state lives here. Carved out of `Solver` so the
// mutable boundary is explicit: every field a chance-node walk mutates is in
// this struct, and chance snapshot/restore is a flat memcpy of one of these.
// Parallel workers will eventually each own their own `BoardContext` over a
// shared immutable evaluator + hand_table + collision tables.
pub const BoardContext = struct {
    board: [5]Card,
    hand_strengths: [NUM_HANDS]u32,
    blocked: [NUM_HANDS]bool,
    sorted_indices: [NUM_HANDS]u16,
    rank_map: [NUM_HANDS]u16,
    first_rank: [NUM_HANDS]u16,
    last_rank: [NUM_HANDS]u16,

    pub fn compute(evaluator: *const Evaluator, hand_table: *const HandTable, board: [5]Card) BoardContext {
        var self: BoardContext = .{
            .board = board,
            .hand_strengths = undefined,
            .blocked = undefined,
            .sorted_indices = undefined,
            .rank_map = undefined,
            .first_rank = undefined,
            .last_rank = undefined,
        };
        self.recompute(evaluator, hand_table, board);
        return self;
    }

    pub fn recompute(self: *BoardContext, evaluator: *const Evaluator, hand_table: *const HandTable, board: [5]Card) void {
        self.board = board;
        for (hand_table.all_hands, 0..) |hand, i| {
            var is_blocked = false;
            for (board) |bc| {
                if (hand.card1 == bc or hand.card2 == bc) {
                    is_blocked = true;
                    break;
                }
            }
            self.blocked[i] = is_blocked;
            if (is_blocked) {
                self.hand_strengths[i] = 0;
            } else {
                const seven = [7]u32{
                    hand.card1, hand.card2,
                    board[0],   board[1],
                    board[2],   board[3],
                    board[4],
                };
                self.hand_strengths[i] = evaluator.handStrength(seven);
            }
            self.sorted_indices[i] = @intCast(i);
        }

        std.mem.sort(u16, &self.sorted_indices, self, struct {
            fn compare(ctx: *const BoardContext, a: u16, b: u16) bool {
                return ctx.hand_strengths[a] < ctx.hand_strengths[b];
            }
        }.compare);

        var r: usize = 0;
        while (r < NUM_HANDS) {
            const start = r;
            const strength = self.hand_strengths[self.sorted_indices[r]];
            while (r < NUM_HANDS and self.hand_strengths[self.sorted_indices[r]] == strength) {
                self.rank_map[self.sorted_indices[r]] = @intCast(r);
                r += 1;
            }
            const end = r - 1;
            for (start..r) |i| {
                const hand_idx = self.sorted_indices[i];
                self.first_rank[hand_idx] = @intCast(start);
                self.last_rank[hand_idx] = @intCast(end);
            }
        }
    }
};

fn boardCardCount(board: [5]Card) usize {
    var count: usize = 0;
    for (board) |c| {
        if (c != 0) count += 1;
    }
    return count;
}

fn boardContains(board: [5]Card, card: Card) bool {
    if (card == 0) return false;
    for (board) |bc| {
        if (bc == card) return true;
    }
    return false;
}

fn handHitsCard(hand: range_mod.Hand, card: Card) bool {
    return hand.card1 == card or hand.card2 == card;
}

fn handBlockedByBoard(hand: range_mod.Hand, board: [5]Card) bool {
    return boardContains(board, hand.card1) or boardContains(board, hand.card2);
}

fn publicChanceCardCount(board: [5]Card) u32 {
    return @intCast(52 - boardCardCount(board));
}

fn legalOneCardChanceCount(board: [5]Card, hand: range_mod.Hand) u32 {
    if (handBlockedByBoard(hand, board)) return 0;
    return publicChanceCardCount(board) - 2;
}

// Per-hand legal runout count, blocker-conditioned on the private hand.
//
// For `cards_to_deal == 2` (flop leaf), this returns the count of *unordered*
// (turn, river) pairs the hand has left. Showdown evaluation is order-
// independent, so `allInEquityLeaf` iterates each unordered pair once instead
// of twice — the per-hand denominator must match.
fn legalRunoutCount(board: [5]Card, hand: range_mod.Hand, cards_to_deal: u8) u32 {
    if (handBlockedByBoard(hand, board)) return 0;
    const public_count = publicChanceCardCount(board);
    return switch (cards_to_deal) {
        0 => 1,
        1 => public_count - 2,
        2 => (public_count - 2) * (public_count - 3) / 2,
        else => unreachable,
    };
}

fn oneCardChanceSampleScale(board: [5]Card, hand: range_mod.Hand, sampled_card: Card) f32 {
    if (handHitsCard(hand, sampled_card)) return 0;
    const legal_count = legalOneCardChanceCount(board, hand);
    if (legal_count == 0) return 0;
    return @as(f32, @floatFromInt(publicChanceCardCount(board))) / @as(f32, @floatFromInt(legal_count));
}

// River-first solver. Holds the static showdown environment (precomputed hand
// strengths against a fixed 5-card board, blocker mask) plus the dense reach
// vectors used during CFR traversal. Solve loop, terminal payoffs, and the
// recursive walker are added in subsequent steps.
pub const Solver = struct {
    evaluator: Evaluator,
    hand_table: HandTable,

    // Stack/pot baseline at the solver root — needed at terminals to recover
    // each player's contribution since root via (initial_stack - edge.stack).
    initial_stack1: f32,
    initial_stack2: f32,
    pot_at_root: f32,

    // Collision map: hand-pairs that share a card. Board-independent, so it
    // stays on the immutable side of the solver — chance walks never touch it.
    collisions: [NUM_HANDS][101]u16,
    collision_counts: [NUM_HANDS]u8,

    // Dense reach vectors derived from the caller's sparse Range inputs at
    // root. Indexed by hand id 0..1325; blocked entries are zero.
    p1_reach: [NUM_HANDS]f32,
    p2_reach: [NUM_HANDS]f32,

    // All board-derived state lives in BoardContext. Chance-node walks mutate
    // this and only this; snapshot/restore is a flat memcpy of the field.
    board_ctx: BoardContext,

    // Pre-computed 5-card BoardContexts for every legal runout off the
    // solver's root board. Built eagerly by `buildRunoutCacheIfNeeded`
    // (called from `cfr.solve` at entry); read-only by the time worker
    // threads start, so no synchronization needed in the hot path.
    //
    // - Root flop (3 cards):  cache has C(49, 2) − blocked pairs (≤ 1,176)
    //                         unordered (turn, river) BoardContexts.
    // - Root turn (4 cards):  cache has up to 48 river BoardContexts.
    // - Root river (5 cards): null. Showdown is single-board, no cache needed.
    //
    // `runout_cache_root` captures the first `boardCardCount` cards of the
    // root board so `allInEquityLeaf` can assert the cache still matches the
    // SolveContext's saved board (paranoia against future code that mutates
    // the root board between init and solve).
    runout_cache: ?[]BoardContext,
    runout_cache_root: [5]Card,
    runout_cache_alloc: ?Allocator,

    // Optional worker-count override for `cfr.solve`. 0 means "use the
    // default cap" (min of cpu_count and MAX_PARALLEL_WORKERS). Any positive
    // value is also clamped to MAX_PARALLEL_WORKERS. Used by the bench
    // harness to sweep parallel scaling without changing the call site.
    max_workers: usize,

    // Io vtable used by the parallel `cfr.solve` path for the worker-pool
    // synchronization primitives (Mutex/Condition) and for the optional
    // per-iter timing accumulator below. Required; callers pass either
    // `init.io` (binaries) or `std.testing.io` (tests).
    io: std.Io,

    // Per-iter timing accumulator for the parallel path. Reset to zero in
    // `init`; updated only when a parallel iter runs. Read after `cfr.solve`
    // returns to attribute wall-clock to spawn / join / merge.
    // `record_timings = false` leaves the accumulator at zero and skips the
    // timestamp syscalls in the inner loop.
    timings: ParallelTimings,
    record_timings: bool,

    pub fn init(
        io: std.Io,
        board: [5]Card,
        p1: *const Range,
        p2: *const Range,
        initial_stack1: f32,
        initial_stack2: f32,
        pot_at_root: f32,
    ) !Solver {
        var self: Solver = .{
            .evaluator = try Evaluator.init(),
            .hand_table = HandTable.init(),
            .initial_stack1 = initial_stack1,
            .initial_stack2 = initial_stack2,
            .pot_at_root = pot_at_root,
            .collisions = undefined,
            .collision_counts = undefined,
            .p1_reach = undefined,
            .p2_reach = undefined,
            .board_ctx = undefined,
            .runout_cache = null,
            .runout_cache_root = .{ 0, 0, 0, 0, 0 },
            .runout_cache_alloc = null,
            .max_workers = 0,
            .io = io,
            .timings = .{},
            .record_timings = false,
        };

        @memset(&self.p1_reach, 0);
        @memset(&self.p2_reach, 0);

        self.board_ctx = BoardContext.compute(&self.evaluator, &self.hand_table, board);

        // Precompute collision map
        for (0..NUM_HANDS) |i| {
            const h_i = self.hand_table.all_hands[i];
            var c_count: u8 = 0;
            for (0..NUM_HANDS) |j| {
                if (i == j) continue;
                const h_j = self.hand_table.all_hands[j];
                if (!handsCompatible(h_i, h_j)) {
                    self.collisions[i][c_count] = @intCast(j);
                    c_count += 1;
                }
            }
            self.collision_counts[i] = c_count;
        }

        for (p1.active_indices, p1.probs) |idx, p| {
            if (!self.board_ctx.blocked[idx]) self.p1_reach[idx] = p;
        }
        for (p2.active_indices, p2.probs) |idx, p| {
            if (!self.board_ctx.blocked[idx]) self.p2_reach[idx] = p;
        }

        return self;
    }

    pub fn deinit(self: *Solver) void {
        if (self.runout_cache) |cache| {
            if (self.runout_cache_alloc) |a| a.free(cache);
            self.runout_cache = null;
            self.runout_cache_alloc = null;
        }
        self.evaluator.deinit();
    }

    // Eagerly populate `runout_cache` for the solver's current root board.
    // No-op if the root board already has 5 cards (no runout enumeration
    // needed) or if the cache is already built. Safe to call multiple times;
    // safe to skip entirely if no caller needs the speedup.
    //
    // Must be called BEFORE any worker threads dispatch — workers read the
    // cache without locks under the assumption that it doesn't change during
    // a solve.
    pub fn buildRunoutCacheIfNeeded(self: *Solver, allocator: Allocator) !void {
        if (self.runout_cache != null) return;
        const root_board = self.board_ctx.board;
        const num_cards = boardCardCount(root_board);
        if (num_cards != 3 and num_cards != 4) return;

        const deck = card_mod.makeDeck();
        var list = std.ArrayList(BoardContext).empty;
        errdefer list.deinit(allocator);

        if (num_cards == 4) {
            for (deck) |r| {
                if (boardContains(root_board, r)) continue;
                var b = root_board;
                b[4] = r;
                try list.append(allocator, BoardContext.compute(&self.evaluator, &self.hand_table, b));
            }
        } else {
            // num_cards == 3: unordered (turn, river) pairs only.
            for (deck, 0..) |t, ti| {
                if (boardContains(root_board, t)) continue;
                for (deck[ti + 1 ..]) |r| {
                    if (boardContains(root_board, r)) continue;
                    var b = root_board;
                    b[3] = t;
                    b[4] = r;
                    try list.append(allocator, BoardContext.compute(&self.evaluator, &self.hand_table, b));
                }
            }
        }

        self.runout_cache = try list.toOwnedSlice(allocator);
        self.runout_cache_root = root_board;
        self.runout_cache_alloc = allocator;
    }

    /// Update the solver's board state for a new runout. Forwards to
    /// `BoardContext.recompute`.
    pub fn reinitForBoard(self: *Solver, board: [5]Card) void {
        self.board_ctx.recompute(&self.evaluator, &self.hand_table, board);
    }

    fn snapshotBoard(self: *const Solver, snap: *BoardContext) void {
        snap.* = self.board_ctx;
    }

    fn restoreBoard(self: *Solver, snap: *const BoardContext) void {
        self.board_ctx = snap.*;
    }

    // EV at a fold terminal. Thin wrapper over `SolveContext.terminalFold`;
    // see there for the real logic. Lives on `Solver` so existing tests can
    // still call `solver.terminalFold(...)` without manually constructing a
    // SolveContext.
    pub fn terminalFold(
        self: *Solver,
        edge: *const Edge,
        folder_isp1: bool,
        p1_reach: []const f32,
        p2_reach: []const f32,
        out_cfv_p1: []f32,
        out_cfv_p2: []f32,
    ) void {
        var ctx = SolveContext.initOnSolver(self);
        ctx.terminalFold(edge, folder_isp1, p1_reach, p2_reach, out_cfv_p1, out_cfv_p2);
    }

    pub fn terminalShowdown(
        self: *Solver,
        edge: *const Edge,
        p1_reach: []const f32,
        p2_reach: []const f32,
        out_cfv_p1: []f32,
        out_cfv_p2: []f32,
    ) void {
        var ctx = SolveContext.initOnSolver(self);
        ctx.terminalShowdown(edge, p1_reach, p2_reach, out_cfv_p1, out_cfv_p2);
    }

    pub fn allInEquityLeaf(
        self: *Solver,
        edge: *const Edge,
        p1_reach: []const f32,
        p2_reach: []const f32,
        out_cfv_p1: []f32,
        out_cfv_p2: []f32,
    ) void {
        var ctx = SolveContext.initOnSolver(self);
        ctx.allInEquityLeaf(edge, p1_reach, p2_reach, out_cfv_p1, out_cfv_p2);
    }
};

// Per-walker context. Bundles a (shared) Solver with a (per-worker) BoardContext
// and a small fixed-size stack of board snapshots for chance save/restore. The
// walker (`walk`/`brWalk`) and the terminal/leaf helpers all operate through a
// `*SolveContext`, which is what makes parallel workers cleanly representable:
// each worker gets its own SolveContext over its own BoardContext, while the
// Solver itself (evaluator, hand_table, collisions, root reaches) is read-only
// shareable across workers.
pub const SolveContext = struct {
    solver: *Solver,
    board_ctx: *BoardContext,
    snapshots: [MAX_CHANCE_DEPTH]BoardContext,
    chance_depth: u8,
    /// When true, `brWalk` may dispatch parallel workers at a chance node.
    /// Workers spawned by such a dispatch set this to false on their own
    /// contexts so recursive chance descents stay serial (no exponential
    /// thread explosion).
    allow_parallel: bool,

    /// Default ctor: a context that mutates the solver's own board_ctx in place.
    pub fn initOnSolver(solver: *Solver) SolveContext {
        return .{
            .solver = solver,
            .board_ctx = &solver.board_ctx,
            .snapshots = undefined,
            .chance_depth = 0,
            .allow_parallel = true,
        };
    }

    /// Worker-style ctor: same Solver (immutable across workers) but a
    /// caller-owned BoardContext so multiple contexts can mutate board state
    /// without colliding. Caller is responsible for the BoardContext lifetime.
    pub fn initOnBoardContext(solver: *Solver, board_ctx: *BoardContext) SolveContext {
        return .{
            .solver = solver,
            .board_ctx = board_ctx,
            .snapshots = undefined,
            .chance_depth = 0,
            .allow_parallel = true,
        };
    }

    pub fn pushSnapshot(self: *SolveContext) void {
        std.debug.assert(self.chance_depth < MAX_CHANCE_DEPTH);
        self.snapshots[self.chance_depth] = self.board_ctx.*;
        self.chance_depth += 1;
    }

    pub fn popSnapshot(self: *SolveContext) void {
        std.debug.assert(self.chance_depth > 0);
        self.chance_depth -= 1;
        self.board_ctx.* = self.snapshots[self.chance_depth];
    }

    pub fn reinitForBoard(self: *SolveContext, board: [5]Card) void {
        self.board_ctx.recompute(&self.solver.evaluator, &self.solver.hand_table, board);
    }

    // EV at a fold terminal. The pot goes to whoever didn't fold; the folder's
    // effective contribution since solver root drives the per-hand payoff.
    // Both per-hand counterfactual value vectors get the payoff weighted by
    // the *opponent's* reach mass that doesn't share cards.
    pub fn terminalFold(
        self: *const SolveContext,
        edge: *const Edge,
        folder_isp1: bool,
        p1_reach: []const f32,
        p2_reach: []const f32,
        out_cfv_p1: []f32,
        out_cfv_p2: []f32,
    ) void {
        const solver = self.solver;
        const eff_c1 = (solver.initial_stack1 - edge.stack1) + solver.pot_at_root / 2.0;
        const eff_c2 = (solver.initial_stack2 - edge.stack2) + solver.pot_at_root / 2.0;
        const folder_loss: f32 = if (folder_isp1) eff_c1 else eff_c2;
        const p1_payoff: f32 = if (folder_isp1) -folder_loss else folder_loss;
        const p2_payoff: f32 = -p1_payoff;

        var p1_total_mass: f32 = 0;
        var p2_total_mass: f32 = 0;
        for (0..NUM_HANDS) |i| {
            p1_total_mass += p1_reach[i];
            p2_total_mass += p2_reach[i];
        }

        for (0..NUM_HANDS) |i| {
            if (self.board_ctx.blocked[i]) {
                out_cfv_p1[i] = 0;
                out_cfv_p2[i] = 0;
                continue;
            }

            var p2_incomp: f32 = 0;
            for (0..solver.collision_counts[i]) |c_idx| {
                p2_incomp += p2_reach[solver.collisions[i][c_idx]];
            }
            out_cfv_p1[i] = p1_payoff * (p2_total_mass - p2_incomp);

            var p1_incomp: f32 = 0;
            for (0..solver.collision_counts[i]) |c_idx| {
                p1_incomp += p1_reach[solver.collisions[i][c_idx]];
            }
            out_cfv_p2[i] = p2_payoff * (p1_total_mass - p1_incomp);
        }
    }

    // EV at a showdown terminal. Each side has matched bets at this point, so
    // both effective contributions equal half the pot; winner of (i vs j) gains
    // half_pot, loser loses it, ties are zero.
    pub fn terminalShowdown(
        self: *const SolveContext,
        edge: *const Edge,
        p1_reach: []const f32,
        p2_reach: []const f32,
        out_cfv_p1: []f32,
        out_cfv_p2: []f32,
    ) void {
        const half_pot: f32 = edge.amount / 2.0;
        self.computeShowdownCFV(p2_reach, out_cfv_p1, half_pot);
        self.computeShowdownCFV(p1_reach, out_cfv_p2, half_pot);
    }

    fn computeShowdownCFV(self: *const SolveContext, reach: []const f32, out: []f32, payoff: f32) void {
        self.computeShowdownCFVFor(self.board_ctx, reach, out, payoff);
    }

    // Showdown CFV against an explicitly-supplied BoardContext. Same logic as
    // `computeShowdownCFV` but lets the caller point at a pre-computed runout
    // (e.g. an entry in `Solver.runout_cache`) without copying it into
    // `self.board_ctx` first.
    fn computeShowdownCFVFor(
        self: *const SolveContext,
        board_ctx: *const BoardContext,
        reach: []const f32,
        out: []f32,
        payoff: f32,
    ) void {
        // Showdown CFV depends on sorted_indices / rank_map / first_rank /
        // last_rank, which are only meaningful at a full 5-card board.
        // Partial-board strengths are computed transiently in the walk but
        // must never reach a showdown — pin the invariant here so future
        // refactors can't silently introduce wrong tie-breaks.
        std.debug.assert(boardCardCount(board_ctx.board) == 5);
        const solver = self.solver;
        var prefix_sum: [NUM_HANDS]f32 = undefined;
        var total_mass: f32 = 0;
        for (0..NUM_HANDS) |r| {
            total_mass += reach[board_ctx.sorted_indices[r]];
            prefix_sum[r] = total_mass;
        }

        for (0..NUM_HANDS) |i| {
            if (board_ctx.blocked[i]) {
                out[i] = 0;
                continue;
            }

            const win_rank_end = @as(i32, @intCast(board_ctx.first_rank[i])) - 1;
            const loss_rank_start = board_ctx.last_rank[i] + 1;

            const naive_win_mass = if (win_rank_end >= 0) prefix_sum[@intCast(win_rank_end)] else 0;
            const naive_loss_mass = if (loss_rank_start < NUM_HANDS) total_mass - prefix_sum[loss_rank_start - 1] else 0;

            var corr_win_mass: f32 = 0;
            var corr_loss_mass: f32 = 0;

            const s_i = board_ctx.hand_strengths[i];
            for (0..solver.collision_counts[i]) |c_idx| {
                const j = solver.collisions[i][c_idx];
                const s_j = board_ctx.hand_strengths[j];
                if (s_j < s_i) {
                    corr_win_mass += reach[j];
                } else if (s_j > s_i) {
                    corr_loss_mass += reach[j];
                }
            }

            const real_win_mass = naive_win_mass - corr_win_mass;
            const real_loss_mass = naive_loss_mass - corr_loss_mass;

            out[i] = (real_win_mass - real_loss_mass) * payoff;
        }
    }

    // All-in equity leaf evaluator. At a chance node we wish to truncate, this
    // returns each player's per-hand CFV under the simplifying assumption that
    // both players commit their remaining stacks immediately and the rest of
    // the board runs out uniformly.
    //
    // Fast path: when `solver.runout_cache` is populated, iterate the cached
    // 5-card BoardContexts directly — no per-runout hand-strength recompute
    // and no `pushSnapshot`/`popSnapshot` round-trip. Cache must be built
    // before any worker walks start; see `Solver.buildRunoutCacheIfNeeded`.
    //
    // Slow path (no cache): preserved for tests and ad-hoc callers that don't
    // go through `cfr.solve`. Save/restore goes through pushSnapshot /
    // popSnapshot so the same chance-depth budget is shared with `walk`.
    //
    // Both paths enumerate flop runouts as *unordered* (turn, river) pairs.
    // Showdown evaluation is order-independent, so the ordered loop was
    // doing 2x the work for no payoff. The per-hand denominator from
    // `legalRunoutCount` matches this convention.
    pub fn allInEquityLeaf(
        self: *SolveContext,
        edge: *const Edge,
        p1_reach: []const f32,
        p2_reach: []const f32,
        out_cfv_p1: []f32,
        out_cfv_p2: []f32,
    ) void {
        const additional: f32 = @min(edge.stack1, edge.stack2);
        const effective_pot: f32 = edge.amount + 2.0 * additional;
        const half_pot: f32 = effective_pot / 2.0;

        @memset(out_cfv_p1, 0);
        @memset(out_cfv_p2, 0);

        const saved_board = self.board_ctx.board;
        const num_board_cards = boardCardCount(saved_board);

        if (num_board_cards == 5) {
            self.computeShowdownCFV(p2_reach, out_cfv_p1, half_pot);
            self.computeShowdownCFV(p1_reach, out_cfv_p2, half_pot);
            return;
        }

        std.debug.assert(num_board_cards == 3 or num_board_cards == 4);

        const hands = self.solver.hand_table.all_hands;
        const cards_to_deal: u8 = if (num_board_cards == 4) 1 else 2;

        if (self.solver.runout_cache) |cache| {
            // Cached fast path. Each entry is a complete 5-card BoardContext
            // pre-computed at solver init for the solver's root board.
            std.debug.assert(std.mem.eql(Card, saved_board[0..num_board_cards], self.solver.runout_cache_root[0..num_board_cards]));

            var runout_cfv_p1: [NUM_HANDS]f32 = undefined;
            var runout_cfv_p2: [NUM_HANDS]f32 = undefined;
            var masked_p1: [NUM_HANDS]f32 = undefined;
            var masked_p2: [NUM_HANDS]f32 = undefined;

            for (cache) |*cached| {
                const new1: Card = if (num_board_cards == 4) cached.board[4] else cached.board[3];
                const new2: Card = if (num_board_cards == 4) 0 else cached.board[4];

                for (0..NUM_HANDS) |i| {
                    const h = hands[i];
                    const keep = !handHitsCard(h, new1) and (new2 == 0 or !handHitsCard(h, new2));
                    masked_p1[i] = if (keep) p1_reach[i] else 0;
                    masked_p2[i] = if (keep) p2_reach[i] else 0;
                }

                self.computeShowdownCFVFor(cached, &masked_p2, &runout_cfv_p1, half_pot);
                self.computeShowdownCFVFor(cached, &masked_p1, &runout_cfv_p2, half_pot);

                for (0..NUM_HANDS) |i| {
                    const h = hands[i];
                    if (handHitsCard(h, new1)) continue;
                    if (new2 != 0 and handHitsCard(h, new2)) continue;
                    out_cfv_p1[i] += runout_cfv_p1[i];
                    out_cfv_p2[i] += runout_cfv_p2[i];
                }
            }
        } else {
            // Slow path: recompute every runout's BoardContext on demand.
            self.pushSnapshot();
            const deck = card_mod.makeDeck();
            var runout_cfv_p1: [NUM_HANDS]f32 = undefined;
            var runout_cfv_p2: [NUM_HANDS]f32 = undefined;

            if (num_board_cards == 4) {
                // Turn-chance leaf: enumerate the river card only.
                for (deck) |r| {
                    if (boardContains(saved_board, r)) continue;

                    var new_board = saved_board;
                    new_board[4] = r;
                    self.reinitForBoard(new_board);

                    var masked_p1: [NUM_HANDS]f32 = undefined;
                    var masked_p2: [NUM_HANDS]f32 = undefined;
                    for (0..NUM_HANDS) |i| {
                        const h = hands[i];
                        const keep = !handHitsCard(h, r);
                        masked_p1[i] = if (keep) p1_reach[i] else 0;
                        masked_p2[i] = if (keep) p2_reach[i] else 0;
                    }

                    self.computeShowdownCFV(&masked_p2, &runout_cfv_p1, half_pot);
                    self.computeShowdownCFV(&masked_p1, &runout_cfv_p2, half_pot);

                    for (0..NUM_HANDS) |i| {
                        const h = hands[i];
                        if (handHitsCard(h, r)) continue;
                        out_cfv_p1[i] += runout_cfv_p1[i];
                        out_cfv_p2[i] += runout_cfv_p2[i];
                    }
                }
            } else {
                // Flop-chance leaf: enumerate (turn, river) unordered pairs.
                for (deck, 0..) |t, ti| {
                    if (boardContains(saved_board, t)) continue;

                    for (deck[ti + 1 ..]) |r| {
                        if (boardContains(saved_board, r)) continue;

                        var new_board = saved_board;
                        new_board[3] = t;
                        new_board[4] = r;
                        self.reinitForBoard(new_board);

                        var masked_p1: [NUM_HANDS]f32 = undefined;
                        var masked_p2: [NUM_HANDS]f32 = undefined;
                        for (0..NUM_HANDS) |i| {
                            const h = hands[i];
                            const keep = !handHitsCard(h, t) and !handHitsCard(h, r);
                            masked_p1[i] = if (keep) p1_reach[i] else 0;
                            masked_p2[i] = if (keep) p2_reach[i] else 0;
                        }

                        self.computeShowdownCFV(&masked_p2, &runout_cfv_p1, half_pot);
                        self.computeShowdownCFV(&masked_p1, &runout_cfv_p2, half_pot);

                        for (0..NUM_HANDS) |i| {
                            const h = hands[i];
                            if (handHitsCard(h, t) or handHitsCard(h, r)) continue;
                            out_cfv_p1[i] += runout_cfv_p1[i];
                            out_cfv_p2[i] += runout_cfv_p2[i];
                        }
                    }
                }
            }

            self.popSnapshot();
        }

        for (0..NUM_HANDS) |i| {
            const h = hands[i];
            const legal_count = legalRunoutCount(saved_board, h, cards_to_deal);
            if (legal_count == 0) {
                out_cfv_p1[i] = 0;
                out_cfv_p2[i] = 0;
            } else {
                const weight: f32 = 1.0 / @as(f32, @floatFromInt(legal_count));
                out_cfv_p1[i] *= weight;
                out_cfv_p2[i] *= weight;
            }
        }
    }
};

inline fn handsCompatible(a: range_mod.Hand, b: range_mod.Hand) bool {
    return a.card1 != b.card1 and a.card1 != b.card2 and a.card2 != b.card1 and a.card2 != b.card2;
}

// Per-worker delta buffers for parallel CFR. Each non-chance / non-leaf node
// gets its own delta slice (same shape as `node.regrets` / `strategy_sum`)
// keyed by `*Node`. During a parallel `solve`, workers write into their own
// `WorkerDeltas` while reading the shared `node.regrets` snapshot from the
// previous iteration's merge. After all workers finish the iteration the main
// thread sums every worker's deltas into the shared tree and applies the
// CFR+ non-negative clamp.
// Per-worker delta entry for a single decision node. The walk writes here with
// `=` (each node is visited once per walk), so no zero-reset is needed between
// iterations: next iter's walk overwrites with fresh values.
pub const NodeDelta = struct {
    node: *Node,
    regret: []f32,
    strategy_sum: []f32,
};

pub const WorkerDeltas = struct {
    arena: std.heap.ArenaAllocator,
    // Lookup by *Node, used by `walk` to find its slot once per node visit.
    regret_delta: std.AutoHashMap(*Node, []f32),
    strategy_sum_delta: std.AutoHashMap(*Node, []f32),
    // Pre-flattened list of all decision-node slots, used by `mergeDeltas` to
    // avoid hashmap lookups in the hot per-iter aggregation loop.
    flat: []NodeDelta,

    pub fn init(parent_allocator: Allocator, root: *Node) !WorkerDeltas {
        var arena = std.heap.ArenaAllocator.init(parent_allocator);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        var rd = std.AutoHashMap(*Node, []f32).init(alloc);
        var ssd = std.AutoHashMap(*Node, []f32).init(alloc);
        var flat = std.ArrayList(NodeDelta).empty;
        try registerDeltaNodes(root, &rd, &ssd, &flat, alloc);
        return .{ .arena = arena, .regret_delta = rd, .strategy_sum_delta = ssd, .flat = flat.items };
    }

    pub fn deinit(self: *WorkerDeltas) void {
        self.arena.deinit();
    }
};

fn registerDeltaNodes(
    node: *Node,
    rd: *std.AutoHashMap(*Node, []f32),
    ssd: *std.AutoHashMap(*Node, []f32),
    flat: *std.ArrayList(NodeDelta),
    alloc: Allocator,
) !void {
    if (node.is_leaf) return;
    if (!node.is_chance and node.regrets.len > 0) {
        const n = node.regrets.len;
        const r = try alloc.alloc(f32, n);
        @memset(r, 0);
        try rd.put(node, r);
        const s = try alloc.alloc(f32, n);
        @memset(s, 0);
        try ssd.put(node, s);
        try flat.append(alloc, .{ .node = node, .regret = r, .strategy_sum = s });
    }
    for (node.edges) |edge| {
        if (edge.child) |child| try registerDeltaNodes(child, rd, ssd, flat, alloc);
    }
}

// Sum every worker's deltas into the shared tree, applying the CFR+ non-
// negative clamp on regret. Each worker's slot is zeroed in the same pass so
// the next iteration's walks can `+=` from a clean baseline without a separate
// reset step. Uses the flat per-worker NodeDelta list — workers all register
// in the same tree-walk order, so the flat-list indices align across workers.
fn mergeDeltas(workers: []const *WorkerDeltas) void {
    if (workers.len == 0) return;
    const n_nodes = workers[0].flat.len;
    var node_idx: usize = 0;
    while (node_idx < n_nodes) : (node_idx += 1) {
        const target = workers[0].flat[node_idx].node;
        const len = target.regrets.len;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            var r_sum: f32 = 0;
            var s_sum: f32 = 0;
            for (workers) |w| {
                r_sum += w.flat[node_idx].regret[i];
                s_sum += w.flat[node_idx].strategy_sum[i];
                w.flat[node_idx].regret[i] = 0;
                w.flat[node_idx].strategy_sum[i] = 0;
            }
            const updated = target.regrets[i] + r_sum;
            target.regrets[i] = if (updated > 0) updated else 0;
            target.strategy_sum[i] += s_sum;
        }
    }
}

// CFR+ with linear-weighted strategy averaging. Cumulative regrets are clipped
// to non-negative inside `walk`, and each iteration's contribution to
// `strategy_sum` is weighted by `iter + 1` so later (more-converged) iterations
// dominate the time-averaged strategy. The dense reach vectors
// (solver.p1_reach / p2_reach) seed the traversal; out buffers receive the
// per-hand counterfactual values from the *last* iteration's walk.
pub fn solve(
    self: *Solver,
    allocator: Allocator,
    root: *Node,
    iterations: usize,
    random: std.Random,
    out_cfv_p1: []f32,
    out_cfv_p2: []f32,
) !void {
    // Build the per-solver runout cache once, before any worker walks start.
    // Cheap when the root board has 5 cards (no-op). For root flop/turn it
    // turns the per-leaf hand-strength recompute into a one-time startup
    // cost amortized across every iteration × every truncated chance leaf.
    try self.buildRunoutCacheIfNeeded(allocator);

    const cpu_count: usize = std.Thread.getCpuCount() catch 1;
    const default_workers: usize = @min(cpu_count, MAX_PARALLEL_WORKERS);
    const n_workers: usize = if (self.max_workers == 0)
        default_workers
    else
        @min(self.max_workers, MAX_PARALLEL_WORKERS);

    if (n_workers <= 1 or iterations == 0) {
        // Serial fallback. No deltas, no thread spawn.
        var ctx = SolveContext.initOnSolver(self);
        var iter: usize = 0;
        while (iter < iterations) : (iter += 1) {
            const iter_weight: f32 = @floatFromInt(iter + 1);
            walk(&ctx, root, &self.p1_reach, &self.p2_reach, out_cfv_p1, out_cfv_p2, random, iter_weight, null);
        }
        return;
    }

    // Parallel path. Per-worker state lives on the dispatcher's stack /
    // dispatcher-managed heap so worker threads only need pointers.
    var worker_boards: [MAX_PARALLEL_WORKERS]BoardContext = undefined;
    var worker_ctxs: [MAX_PARALLEL_WORKERS]SolveContext = undefined;
    var worker_deltas: [MAX_PARALLEL_WORKERS]WorkerDeltas = undefined;
    var worker_prngs: [MAX_PARALLEL_WORKERS]std.Random.DefaultPrng = undefined;
    var worker_out_p1: [MAX_PARALLEL_WORKERS][NUM_HANDS]f32 = undefined;
    var worker_out_p2: [MAX_PARALLEL_WORKERS][NUM_HANDS]f32 = undefined;
    var worker_ptrs: [MAX_PARALLEL_WORKERS]*WorkerDeltas = undefined;

    // Seed each worker's PRNG deterministically from the caller's `random` so
    // results are reproducible given a fixed input seed.
    const base_seed: u64 = random.int(u64);

    var initialized: usize = 0;
    errdefer for (0..initialized) |t| worker_deltas[t].deinit();
    var t: usize = 0;
    while (t < n_workers) : (t += 1) {
        worker_boards[t] = self.board_ctx;
        worker_ctxs[t] = SolveContext.initOnBoardContext(self, &worker_boards[t]);
        worker_ctxs[t].allow_parallel = false;
        worker_deltas[t] = try WorkerDeltas.init(allocator, root);
        initialized = t + 1;
        worker_prngs[t] = std.Random.DefaultPrng.init(base_seed +% t);
        worker_ptrs[t] = &worker_deltas[t];
    }
    defer for (0..n_workers) |i| worker_deltas[i].deinit();

    // Persistent worker pool: spawn once, dispatch each iter via an epoch
    // bump on a shared condvar. Replaces the previous per-iter spawn/join
    // (~0.3-1.3ms/iter at workers=2..8 in release).
    var pool: ParallelPool = .{};
    var workers: [MAX_PARALLEL_WORKERS]PoolWorker = undefined;
    var threads: [MAX_PARALLEL_WORKERS]std.Thread = undefined;

    const io = self.io;
    var s: usize = 0;
    while (s < n_workers) : (s += 1) {
        workers[s] = .{
            .pool = &pool,
            .io = io,
            .job = .{
                .ctx = &worker_ctxs[s],
                .root = root,
                .p1_reach = &self.p1_reach,
                .p2_reach = &self.p2_reach,
                .out_cfv_p1 = &worker_out_p1[s],
                .out_cfv_p2 = &worker_out_p2[s],
                .random = worker_prngs[s].random(),
                .iter_weight = 0,
                .deltas = &worker_deltas[s],
            },
        };
    }

    // Spawn workers. If the OS refuses partway through, shut down the
    // workers we did spawn and fall back to the serial loop — same outcome
    // as the previous code's spawn-failure branch, just at a different scope.
    var spawned: usize = 0;
    while (spawned < n_workers) {
        if (std.Thread.spawn(.{}, PoolWorker.run, .{&workers[spawned]})) |th| {
            threads[spawned] = th;
            spawned += 1;
        } else |_| {
            break;
        }
    }
    pool.n_workers = spawned;

    if (spawned <= 1) {
        if (spawned == 1) {
            pool.mutex.lockUncancelable(io);
            pool.shutdown = true;
            pool.mutex.unlock(io);
            pool.job_cv.broadcast(io);
            threads[0].join();
        }
        var ctx2 = SolveContext.initOnSolver(self);
        var iter2: usize = 0;
        while (iter2 < iterations) : (iter2 += 1) {
            const iter_weight: f32 = @floatFromInt(iter2 + 1);
            walk(&ctx2, root, &self.p1_reach, &self.p2_reach, out_cfv_p1, out_cfv_p2, random, iter_weight, null);
        }
        return;
    }

    // From here on, `spawned` workers are parked on `job_cv` waiting for the
    // first epoch. Shutdown on any exit path joins them cleanly.
    defer {
        pool.mutex.lockUncancelable(io);
        pool.shutdown = true;
        pool.mutex.unlock(io);
        pool.job_cv.broadcast(io);
        for (0..spawned) |i| threads[i].join();
    }

    const actual_workers = spawned;
    const record = self.record_timings;

    // `iterations` is the number of strategy updates — same semantics as the
    // serial loop. Each update dispatches N parallel walks that contribute
    // lower-variance samples to the per-update delta, then merges.
    var iter: usize = 0;
    while (iter < iterations) : (iter += 1) {
        const iter_weight: f32 = @floatFromInt(iter + 1);

        const t_iter_start: ?std.Io.Clock.Timestamp = if (record)
            std.Io.Clock.Timestamp.now(io, .awake)
        else
            null;

        // Workers are parked: safe to mutate their job's per-iter field
        // without the pool lock. The lock + broadcast below publishes.
        for (0..actual_workers) |w| workers[w].job.iter_weight = iter_weight;

        pool.mutex.lockUncancelable(io);
        pool.workers_done = 0;
        pool.epoch += 1;
        pool.mutex.unlock(io);
        pool.job_cv.broadcast(io);

        const t_after_spawn: ?std.Io.Clock.Timestamp = if (record)
            std.Io.Clock.Timestamp.now(io, .awake)
        else
            null;

        pool.mutex.lockUncancelable(io);
        while (pool.workers_done < actual_workers) pool.done_cv.waitUncancelable(io, &pool.mutex);
        pool.mutex.unlock(io);

        const t_after_join: ?std.Io.Clock.Timestamp = if (record)
            std.Io.Clock.Timestamp.now(io, .awake)
        else
            null;

        mergeDeltas(worker_ptrs[0..actual_workers]);

        if (record) {
            const t_after_merge = std.Io.Clock.Timestamp.now(io, .awake);
            self.timings.iter_count += 1;
            // spawn_ns now measures the dispatch (lock + epoch bump + broadcast)
            // rather than `std.Thread.spawn`; field name retained so the bench
            // output stays comparable across the change.
            self.timings.spawn_ns += timestampDeltaNs(t_iter_start.?, t_after_spawn.?);
            self.timings.join_ns += timestampDeltaNs(t_after_spawn.?, t_after_join.?);
            self.timings.merge_ns += timestampDeltaNs(t_after_join.?, t_after_merge);
        }
    }

    // Return the last iter's worker-0 CFVs (the public out-buffers are an
    // observational hook, not a load-bearing equilibrium value).
    @memcpy(out_cfv_p1, &worker_out_p1[0]);
    @memcpy(out_cfv_p2, &worker_out_p2[0]);
}

const WalkJob = struct {
    ctx: *SolveContext,
    root: *Node,
    p1_reach: []const f32,
    p2_reach: []const f32,
    out_cfv_p1: *[NUM_HANDS]f32,
    out_cfv_p2: *[NUM_HANDS]f32,
    random: std.Random,
    iter_weight: f32,
    deltas: *WorkerDeltas,

    fn run(self: *WalkJob) void {
        walk(self.ctx, self.root, self.p1_reach, self.p2_reach, self.out_cfv_p1, self.out_cfv_p2, self.random, self.iter_weight, self.deltas);
    }
};

// Coordinates the persistent worker pool used by `solve`. One instance lives
// on the dispatcher's stack for the duration of a single `solve` call; the
// pool is torn down before `solve` returns. Workers park on `job_cv` between
// iterations and wake when `epoch` advances. `done_cv` is signaled when
// `workers_done` reaches `n_workers`, releasing the dispatcher to merge.
//
// All state under `mutex` — no atomics needed; the lock pairing with the
// condition variables provides the memory ordering for per-iter `WalkJob`
// updates (the dispatcher writes `iter_weight` while workers are parked, then
// the broadcast/wake pair publishes those writes).
const ParallelPool = struct {
    // `std.Io.Mutex`/`Condition` need an `Io` on every call — passed in
    // alongside `pool` from the dispatcher's stack so workers don't have to
    // chase a back-pointer to the Solver.
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    job_cv: std.Io.Condition = std.Io.Condition.init,
    done_cv: std.Io.Condition = std.Io.Condition.init,
    epoch: u64 = 0,
    workers_done: usize = 0,
    n_workers: usize = 0,
    shutdown: bool = false,
};

// One persistent worker. `job` is filled by the dispatcher before the pool
// is started and only `job.iter_weight` is updated between epochs.
const PoolWorker = struct {
    pool: *ParallelPool,
    io: std.Io,
    job: WalkJob,

    fn run(self: *PoolWorker) void {
        var last_epoch: u64 = 0;
        while (true) {
            self.pool.mutex.lockUncancelable(self.io);
            while (!self.pool.shutdown and self.pool.epoch == last_epoch) {
                self.pool.job_cv.waitUncancelable(self.io, &self.pool.mutex);
            }
            if (self.pool.shutdown) {
                self.pool.mutex.unlock(self.io);
                return;
            }
            const my_epoch = self.pool.epoch;
            self.pool.mutex.unlock(self.io);

            WalkJob.run(&self.job);

            last_epoch = my_epoch;
            self.pool.mutex.lockUncancelable(self.io);
            self.pool.workers_done += 1;
            if (self.pool.workers_done == self.pool.n_workers) {
                self.pool.done_cv.signal(self.io);
            }
            self.pool.mutex.unlock(self.io);
        }
    }
};

// Single recursive pass. Computes per-hand CFV for both players, then updates
// the acting player's regrets and strategy_sum using vanilla CFR's update rule.
// Both players' regret tables get updated across the full walk (one iteration
// = one tree traversal), since each decision node belongs to exactly one of
// them and only that player's tables get touched there.
fn walk(
    ctx: *SolveContext,
    node: *Node,
    p1_reach: []const f32,
    p2_reach: []const f32,
    out_cfv_p1: []f32,
    out_cfv_p2: []f32,
    random: std.Random,
    iter_weight: f32,
    deltas: ?*WorkerDeltas,
) void {
    const hands = ctx.solver.hand_table.all_hands;

    if (node.is_chance) {
        if (node.is_leaf) {
            ctx.allInEquityLeaf(&node.edges[0], p1_reach, p2_reach, out_cfv_p1, out_cfv_p2);
            return;
        }

        // Chance-Sampled CFR: Sample a single runout instead of enumerating all.
        ctx.pushSnapshot();
        const saved_board = ctx.board_ctx.board;
        const num_board_cards = boardCardCount(saved_board);
        const card_to_fill_idx: usize = if (num_board_cards == 3) @as(usize, 3) else @as(usize, 4);

        const deck = card_mod.makeDeck();
        var c: u32 = 0;
        while (true) {
            c = deck[random.uintLessThan(usize, 52)];
            if (!boardContains(saved_board, c)) break;
        }

        var new_board = saved_board;
        new_board[card_to_fill_idx] = c;

        // Update strengths for this sampled runout
        ctx.reinitForBoard(new_board);

        // Card removal: hands containing the sampled card become illegal on the
        // new board. Zero their reach before recursing so downstream regret /
        // strategy_sum updates don't accumulate mass for hands that aren't in
        // the player's effective range on this runout.
        var masked_p1_reach: [NUM_HANDS]f32 = undefined;
        var masked_p2_reach: [NUM_HANDS]f32 = undefined;
        for (0..NUM_HANDS) |i| {
            const h = hands[i];
            const keep = !handHitsCard(h, c);
            masked_p1_reach[i] = if (keep) p1_reach[i] else 0;
            masked_p2_reach[i] = if (keep) p2_reach[i] else 0;
        }

        // Recurse into the single chance child (Action.CHANCE).
        // In sampled CFR, we don't weight by 1/N because the sampling distribution
        // (uniform over legal cards) naturally handles the probability over iterations.
        // A null child means the chance edge leads directly to a showdown — happens
        // when an all-in is called pre-river, so the runout chain ends in showdown
        // rather than another decision node.
        const chance_edge = &node.edges[0];
        if (chance_edge.child) |child| {
            walk(ctx, child, &masked_p1_reach, &masked_p2_reach, out_cfv_p1, out_cfv_p2, random, iter_weight, deltas);
        } else {
            ctx.terminalShowdown(chance_edge, &masked_p1_reach, &masked_p2_reach, out_cfv_p1, out_cfv_p2);
        }

        // The sample is drawn uniformly from public cards. Per-hand CFVs need
        // to be conditioned on that hand's blockers, so legal samples get an
        // importance correction and illegal samples stay at zero.
        for (0..NUM_HANDS) |i| {
            const h = hands[i];
            const scale = oneCardChanceSampleScale(saved_board, h, c);
            if (scale == 0) {
                out_cfv_p1[i] = 0;
                out_cfv_p2[i] = 0;
            } else {
                out_cfv_p1[i] *= scale;
                out_cfv_p2[i] *= scale;
            }
        }

        // Restore via cheap memcpy snapshot rather than redoing a full
        // hand-strength + sort recompute on the way out.
        ctx.popSnapshot();
        return;
    }

    const n_actions = node.edges.len;
    const actor_isp1 = node.isp1;

    // --- 1. Regret matching → current strategy (per-hand). ---
    var strategy: [MAX_ACTIONS * NUM_HANDS]f32 = undefined;
    {
        var i: usize = 0;
        while (i < NUM_HANDS) : (i += 1) {
            var pos_sum: f32 = 0;
            var a: usize = 0;
            while (a < n_actions) : (a += 1) {
                const r = node.regrets[a * NUM_HANDS + i];
                if (r > 0) pos_sum += r;
            }
            if (pos_sum > 0) {
                a = 0;
                while (a < n_actions) : (a += 1) {
                    const r = node.regrets[a * NUM_HANDS + i];
                    strategy[a * NUM_HANDS + i] = if (r > 0) r / pos_sum else 0;
                }
            } else {
                const uniform: f32 = 1.0 / @as(f32, @floatFromInt(n_actions));
                a = 0;
                while (a < n_actions) : (a += 1) {
                    strategy[a * NUM_HANDS + i] = uniform;
                }
            }
        }
    }

    // --- 2. Recurse into each child, filling per-action CFV slots. ---
    var child_cfv_p1: [MAX_ACTIONS * NUM_HANDS]f32 = undefined;
    var child_cfv_p2: [MAX_ACTIONS * NUM_HANDS]f32 = undefined;
    var new_p1_reach: [NUM_HANDS]f32 = undefined;
    var new_p2_reach: [NUM_HANDS]f32 = undefined;

    for (node.edges, 0..) |*edge, a| {
        const off = a * NUM_HANDS;
        // Only the actor's reach gets scaled by their strategy on this action.
        if (actor_isp1) {
            var i: usize = 0;
            while (i < NUM_HANDS) : (i += 1) {
                new_p1_reach[i] = p1_reach[i] * strategy[off + i];
                new_p2_reach[i] = p2_reach[i];
            }
        } else {
            var i: usize = 0;
            while (i < NUM_HANDS) : (i += 1) {
                new_p1_reach[i] = p1_reach[i];
                new_p2_reach[i] = p2_reach[i] * strategy[off + i];
            }
        }

        const cfv_p1_slot = child_cfv_p1[off .. off + NUM_HANDS];
        const cfv_p2_slot = child_cfv_p2[off .. off + NUM_HANDS];

        if (edge.child) |child| {
            walk(ctx, child, &new_p1_reach, &new_p2_reach, cfv_p1_slot, cfv_p2_slot, random, iter_weight, deltas);
        } else {
            switch (edge.action) {
                .FOLD => ctx.terminalFold(edge, actor_isp1, &new_p1_reach, &new_p2_reach, cfv_p1_slot, cfv_p2_slot),
                .CHECK, .CALL => ctx.terminalShowdown(edge, &new_p1_reach, &new_p2_reach, cfv_p1_slot, cfv_p2_slot),
                else => unreachable,
            }
        }
    }

    // --- 3. Combine child CFVs into the node-level CFV. ---
    // Actor mixes over actions on their own hand; opponent's CFV is summed
    // straight across (their actor-strategy scaling is baked into the reach
    // we passed into each child).
    @memset(out_cfv_p1, 0);
    @memset(out_cfv_p2, 0);
    if (actor_isp1) {
        var a: usize = 0;
        while (a < n_actions) : (a += 1) {
            const off = a * NUM_HANDS;
            var i: usize = 0;
            while (i < NUM_HANDS) : (i += 1) {
                out_cfv_p1[i] += strategy[off + i] * child_cfv_p1[off + i];
                out_cfv_p2[i] += child_cfv_p2[off + i];
            }
        }
    } else {
        var a: usize = 0;
        while (a < n_actions) : (a += 1) {
            const off = a * NUM_HANDS;
            var i: usize = 0;
            while (i < NUM_HANDS) : (i += 1) {
                out_cfv_p1[i] += child_cfv_p1[off + i];
                out_cfv_p2[i] += strategy[off + i] * child_cfv_p2[off + i];
            }
        }
    }

    // --- 4. Regret + strategy_sum updates for the actor at this node. ---
    // CFR+ regret matching: cumulative regret is clipped to non-negative after
    // each increment. Strategy averaging is linearly weighted by iter_weight so
    // late iterations (near-equilibrium) dominate over early uniform play.
    //
    // Parallel path: when `deltas` is non-null, write the per-worker delta
    // instead of mutating the shared `node.regrets` / `node.strategy_sum`. The
    // CFR+ clamp is applied later in `mergeDeltas` against the merged sum, not
    // per-walk (otherwise N workers clamping independently would lose mass).
    if (deltas) |d| {
        // Workers `+=` into their delta slots. `mergeDeltas` zeros the slots
        // after reading, so each iteration starts from zero without a separate
        // reset pass. (CS-CFR samples different chance paths each iter, so we
        // can't rely on the same set of decision nodes being touched.)
        const r_delta = d.regret_delta.get(node).?;
        const s_delta = d.strategy_sum_delta.get(node).?;
        if (actor_isp1) {
            var a: usize = 0;
            while (a < n_actions) : (a += 1) {
                const off = a * NUM_HANDS;
                var i: usize = 0;
                while (i < NUM_HANDS) : (i += 1) {
                    r_delta[off + i] += child_cfv_p1[off + i] - out_cfv_p1[i];
                    s_delta[off + i] += iter_weight * p1_reach[i] * strategy[off + i];
                }
            }
        } else {
            var a: usize = 0;
            while (a < n_actions) : (a += 1) {
                const off = a * NUM_HANDS;
                var i: usize = 0;
                while (i < NUM_HANDS) : (i += 1) {
                    r_delta[off + i] += child_cfv_p2[off + i] - out_cfv_p2[i];
                    s_delta[off + i] += iter_weight * p2_reach[i] * strategy[off + i];
                }
            }
        }
    } else if (actor_isp1) {
        var a: usize = 0;
        while (a < n_actions) : (a += 1) {
            const off = a * NUM_HANDS;
            var i: usize = 0;
            while (i < NUM_HANDS) : (i += 1) {
                const updated = node.regrets[off + i] + (child_cfv_p1[off + i] - out_cfv_p1[i]);
                node.regrets[off + i] = if (updated > 0) updated else 0;
                node.strategy_sum[off + i] += iter_weight * p1_reach[i] * strategy[off + i];
            }
        }
    } else {
        var a: usize = 0;
        while (a < n_actions) : (a += 1) {
            const off = a * NUM_HANDS;
            var i: usize = 0;
            while (i < NUM_HANDS) : (i += 1) {
                const updated = node.regrets[off + i] + (child_cfv_p2[off + i] - out_cfv_p2[i]);
                node.regrets[off + i] = if (updated > 0) updated else 0;
                node.strategy_sum[off + i] += iter_weight * p2_reach[i] * strategy[off + i];
            }
        }
    }
}

// Best response: walks the tree with the BR player picking max-EV action per
// hand at their own decision nodes, while the opponent plays their *average*
// strategy from strategy_sum. Writes per-hand BR CFV (from BR's perspective)
// into out_cfv. Used to measure exploitability.
fn brWalk(
    ctx: *SolveContext,
    node: *Node,
    p1_reach: []const f32,
    p2_reach: []const f32,
    br_isp1: bool,
    out_cfv: []f32,
) void {
    const hands = ctx.solver.hand_table.all_hands;

    if (node.is_chance) {
        if (node.is_leaf) {
            var dummy: [NUM_HANDS]f32 = undefined;
            if (br_isp1) {
                ctx.allInEquityLeaf(&node.edges[0], p1_reach, p2_reach, out_cfv, &dummy);
            } else {
                ctx.allInEquityLeaf(&node.edges[0], p1_reach, p2_reach, &dummy, out_cfv);
            }
            return;
        }

        ctx.pushSnapshot();
        const saved_board = ctx.board_ctx.board;
        const saved_board_ctx = ctx.board_ctx.*;
        const num_board_cards = boardCardCount(saved_board);
        const card_to_fill_idx: usize = if (num_board_cards == 3) @as(usize, 3) else @as(usize, 4);

        // Filter to legal cards up front so the parallel dispatch can carve
        // the workload evenly without per-worker reblocker checks.
        var legal_cards: [52]u32 = undefined;
        var n_legal: usize = 0;
        const deck = card_mod.makeDeck();
        for (deck) |c| {
            if (!boardContains(saved_board, c)) {
                legal_cards[n_legal] = c;
                n_legal += 1;
            }
        }

        const cpu_count: usize = std.Thread.getCpuCount() catch 1;
        const n_workers: usize = blk: {
            if (!ctx.allow_parallel) break :blk 1;
            const want = @min(cpu_count, MAX_PARALLEL_WORKERS);
            break :blk @min(want, n_legal);
        };

        if (n_workers <= 1) {
            // Serial path: run the worker body once over the full legal slice.
            @memset(out_cfv, 0);
            brChanceWorker(ctx, node, saved_board, card_to_fill_idx, legal_cards[0..n_legal], p1_reach, p2_reach, br_isp1, out_cfv);
        } else {
            // Parallel path: per-worker BoardContext + SolveContext + output slot.
            var worker_boards: [MAX_PARALLEL_WORKERS]BoardContext = undefined;
            var worker_ctxs: [MAX_PARALLEL_WORKERS]SolveContext = undefined;
            var worker_outs: [MAX_PARALLEL_WORKERS][NUM_HANDS]f32 = undefined;
            var threads: [MAX_PARALLEL_WORKERS]std.Thread = undefined;
            var jobs: [MAX_PARALLEL_WORKERS]BrChanceJob = undefined;

            var t: usize = 0;
            while (t < n_workers) : (t += 1) {
                const start = (t * n_legal) / n_workers;
                const end = ((t + 1) * n_legal) / n_workers;

                worker_boards[t] = saved_board_ctx;
                worker_ctxs[t] = SolveContext.initOnBoardContext(ctx.solver, &worker_boards[t]);
                worker_ctxs[t].allow_parallel = false;

                jobs[t] = .{
                    .ctx = &worker_ctxs[t],
                    .node = node,
                    .saved_board = saved_board,
                    .card_to_fill_idx = card_to_fill_idx,
                    .legal_cards = legal_cards[start..end],
                    .p1_reach = p1_reach,
                    .p2_reach = p2_reach,
                    .br_isp1 = br_isp1,
                    .out_cfv = &worker_outs[t],
                };

                threads[t] = std.Thread.spawn(.{}, BrChanceJob.run, .{&jobs[t]}) catch {
                    // Spawn failed: run synchronously inline so we don't lose the slice.
                    BrChanceJob.run(&jobs[t]);
                    // Join any threads already spawned, then bail out of the loop.
                    var j: usize = 0;
                    while (j < t) : (j += 1) threads[j].join();
                    break;
                };
            }
            // If we exited the spawn loop normally, t == n_workers. If a spawn
            // failed, the catch block joined earlier threads, ran the failing
            // slice synchronously, and broke; t names the next index to skip.
            const joined_target = if (t == n_workers) n_workers else t;
            var j: usize = 0;
            while (j < joined_target) : (j += 1) threads[j].join();

            // Aggregate worker slots into out_cfv.
            for (0..NUM_HANDS) |i| {
                var sum: f32 = 0;
                var k: usize = 0;
                while (k < n_workers) : (k += 1) sum += worker_outs[k][i];
                out_cfv[i] = sum;
            }
        }

        ctx.popSnapshot();
        for (0..NUM_HANDS) |i| {
            const h = hands[i];
            const legal_count = legalOneCardChanceCount(saved_board, h);
            if (legal_count == 0) {
                out_cfv[i] = 0;
            } else {
                out_cfv[i] /= @floatFromInt(legal_count);
            }
        }
        return;
    }

    const n_actions = node.edges.len;
    const actor_isp1 = node.isp1;

    if (actor_isp1 == br_isp1) {
        // BR player's decision: walk every action with unchanged reach, then
        // pick the per-hand max. Opponent's reach doesn't change here either,
        // since BR plays a pure (per-hand) strategy.
        var child_cfv: [MAX_ACTIONS * NUM_HANDS]f32 = undefined;
        var dummy: [NUM_HANDS]f32 = undefined;
        for (node.edges, 0..) |*edge, a| {
            const off = a * NUM_HANDS;
            const slot = child_cfv[off .. off + NUM_HANDS];
            if (edge.child) |child| {
                brWalk(ctx, child, p1_reach, p2_reach, br_isp1, slot);
            } else if (br_isp1) {
                switch (edge.action) {
                    .FOLD => ctx.terminalFold(edge, actor_isp1, p1_reach, p2_reach, slot, &dummy),
                    .CHECK, .CALL => ctx.terminalShowdown(edge, p1_reach, p2_reach, slot, &dummy),
                    else => unreachable,
                }
            } else {
                switch (edge.action) {
                    .FOLD => ctx.terminalFold(edge, actor_isp1, p1_reach, p2_reach, &dummy, slot),
                    .CHECK, .CALL => ctx.terminalShowdown(edge, p1_reach, p2_reach, &dummy, slot),
                    else => unreachable,
                }
            }
        }
        var i: usize = 0;
        while (i < NUM_HANDS) : (i += 1) {
            var best: f32 = child_cfv[i];
            var a: usize = 1;
            while (a < n_actions) : (a += 1) {
                const v = child_cfv[a * NUM_HANDS + i];
                if (v > best) best = v;
            }
            out_cfv[i] = best;
        }
    } else {
        // Opponent's decision: normalize strategy_sum → average strategy, scale
        // opponent's reach by it per action, and sum the child CFVs.
        var avg_strategy: [MAX_ACTIONS * NUM_HANDS]f32 = undefined;
        {
            var i: usize = 0;
            while (i < NUM_HANDS) : (i += 1) {
                var sum: f32 = 0;
                var a: usize = 0;
                while (a < n_actions) : (a += 1) sum += node.strategy_sum[a * NUM_HANDS + i];
                if (sum > 0) {
                    a = 0;
                    while (a < n_actions) : (a += 1) {
                        avg_strategy[a * NUM_HANDS + i] = node.strategy_sum[a * NUM_HANDS + i] / sum;
                    }
                } else {
                    const uniform: f32 = 1.0 / @as(f32, @floatFromInt(n_actions));
                    a = 0;
                    while (a < n_actions) : (a += 1) avg_strategy[a * NUM_HANDS + i] = uniform;
                }
            }
        }

        @memset(out_cfv, 0);
        var new_p1_reach: [NUM_HANDS]f32 = undefined;
        var new_p2_reach: [NUM_HANDS]f32 = undefined;
        var child_cfv: [NUM_HANDS]f32 = undefined;
        var dummy: [NUM_HANDS]f32 = undefined;

        for (node.edges, 0..) |*edge, a| {
            const off = a * NUM_HANDS;
            if (br_isp1) {
                var i: usize = 0;
                while (i < NUM_HANDS) : (i += 1) {
                    new_p1_reach[i] = p1_reach[i];
                    new_p2_reach[i] = p2_reach[i] * avg_strategy[off + i];
                }
            } else {
                var i: usize = 0;
                while (i < NUM_HANDS) : (i += 1) {
                    new_p1_reach[i] = p1_reach[i] * avg_strategy[off + i];
                    new_p2_reach[i] = p2_reach[i];
                }
            }

            if (edge.child) |child| {
                brWalk(ctx, child, &new_p1_reach, &new_p2_reach, br_isp1, &child_cfv);
            } else if (br_isp1) {
                switch (edge.action) {
                    .FOLD => ctx.terminalFold(edge, actor_isp1, &new_p1_reach, &new_p2_reach, &child_cfv, &dummy),
                    .CHECK, .CALL => ctx.terminalShowdown(edge, &new_p1_reach, &new_p2_reach, &child_cfv, &dummy),
                    else => unreachable,
                }
            } else {
                switch (edge.action) {
                    .FOLD => ctx.terminalFold(edge, actor_isp1, &new_p1_reach, &new_p2_reach, &dummy, &child_cfv),
                    .CHECK, .CALL => ctx.terminalShowdown(edge, &new_p1_reach, &new_p2_reach, &dummy, &child_cfv),
                    else => unreachable,
                }
            }

            var i: usize = 0;
            while (i < NUM_HANDS) : (i += 1) out_cfv[i] += child_cfv[i];
        }
    }
}

// One unit of parallel work for `brWalk`'s chance-node enumeration: iterate a
// slice of legal cards, accumulate per-card runout CFVs into a worker-private
// output buffer. The chance-edge structure and root-side state come in via the
// `node`/`saved_board` fields. Each worker holds its own `*SolveContext` over
// its own `BoardContext` (allocated in the dispatcher frame) so `reinitForBoard`
// calls don't collide.
const BrChanceJob = struct {
    ctx: *SolveContext,
    node: *Node,
    saved_board: [5]Card,
    card_to_fill_idx: usize,
    legal_cards: []const u32,
    p1_reach: []const f32,
    p2_reach: []const f32,
    br_isp1: bool,
    out_cfv: *[NUM_HANDS]f32,

    fn run(self: *BrChanceJob) void {
        @memset(self.out_cfv, 0);
        brChanceWorker(self.ctx, self.node, self.saved_board, self.card_to_fill_idx, self.legal_cards, self.p1_reach, self.p2_reach, self.br_isp1, self.out_cfv);
    }
};

// Per-card runout body shared by the serial and parallel paths of `brWalk`.
// Accumulates into `out_cfv` (additive — caller is responsible for zeroing or
// for one-shot writes). Performs no per-hand averaging; that's a single final
// pass back in `brWalk` after slot aggregation.
fn brChanceWorker(
    ctx: *SolveContext,
    node: *Node,
    saved_board: [5]Card,
    card_to_fill_idx: usize,
    legal_cards: []const u32,
    p1_reach: []const f32,
    p2_reach: []const f32,
    br_isp1: bool,
    out_cfv: []f32,
) void {
    const hands = ctx.solver.hand_table.all_hands;
    var runout_cfv: [NUM_HANDS]f32 = undefined;

    for (legal_cards) |c| {
        var new_board = saved_board;
        new_board[card_to_fill_idx] = c;
        ctx.reinitForBoard(new_board);

        var masked_p1: [NUM_HANDS]f32 = undefined;
        var masked_p2: [NUM_HANDS]f32 = undefined;
        for (0..NUM_HANDS) |i| {
            const h = hands[i];
            const keep = !handHitsCard(h, c);
            masked_p1[i] = if (keep) p1_reach[i] else 0;
            masked_p2[i] = if (keep) p2_reach[i] else 0;
        }

        const chance_edge = &node.edges[0];
        if (chance_edge.child) |child| {
            brWalk(ctx, child, &masked_p1, &masked_p2, br_isp1, &runout_cfv);
        } else {
            var dummy: [NUM_HANDS]f32 = undefined;
            if (br_isp1) {
                ctx.terminalShowdown(chance_edge, &masked_p1, &masked_p2, &runout_cfv, &dummy);
            } else {
                ctx.terminalShowdown(chance_edge, &masked_p1, &masked_p2, &dummy, &runout_cfv);
            }
        }

        for (0..NUM_HANDS) |i| {
            const h = hands[i];
            if (handHitsCard(h, c)) continue;
            out_cfv[i] += runout_cfv[i];
        }
    }
}

// Public strategy-extraction API. `node` must be a non-chance decision node.
// `out` must be sized `node.edges.len * NUM_HANDS`, laid out as
// `out[action * NUM_HANDS + hand_idx]`, matching the internal regret /
// strategy_sum layout. For hands with zero accumulated mass (never reached
// during solving) the uniform distribution is returned.
pub fn averageStrategy(node: *const Node, out: []f32) void {
    std.debug.assert(!node.is_chance);
    const n = node.edges.len;
    std.debug.assert(out.len == n * NUM_HANDS);
    const uniform: f32 = 1.0 / @as(f32, @floatFromInt(n));
    var i: usize = 0;
    while (i < NUM_HANDS) : (i += 1) {
        var sum: f32 = 0;
        var a: usize = 0;
        while (a < n) : (a += 1) sum += node.strategy_sum[a * NUM_HANDS + i];
        if (sum > 0) {
            a = 0;
            while (a < n) : (a += 1) {
                out[a * NUM_HANDS + i] = node.strategy_sum[a * NUM_HANDS + i] / sum;
            }
        } else {
            a = 0;
            while (a < n) : (a += 1) out[a * NUM_HANDS + i] = uniform;
        }
    }
}

pub fn bestResponse(self: *Solver, root: *Node, br_isp1: bool, out_cfv: []f32) void {
    var ctx = SolveContext.initOnSolver(self);
    bestResponseWith(&ctx, root, br_isp1, out_cfv);
}

/// Ctx-taking BR entry point. The reach vectors live on the Solver (immutable)
/// so a caller-owned SolveContext over a separate BoardContext can run on its
/// own thread without colliding with another worker.
pub fn bestResponseWith(ctx: *SolveContext, root: *Node, br_isp1: bool, out_cfv: []f32) void {
    brWalk(ctx, root, &ctx.solver.p1_reach, &ctx.solver.p2_reach, br_isp1, out_cfv);
}

const BrJob = struct {
    ctx: *SolveContext,
    root: *Node,
    br_isp1: bool,
    out_cfv: []f32,

    fn run(self: BrJob) void {
        bestResponseWith(self.ctx, self.root, self.br_isp1, self.out_cfv);
    }
};

// Sum of best-response values for both players, weighted by their reach. At a
// Nash equilibrium this is zero (zero-sum game); any positive value is how
// much can be extracted by exploiting the current average strategies.
//
// The two BR walks are independent and run on two threads. Each thread gets
// its own SolveContext over its own BoardContext copy so neither side's chance
// enumeration corrupts the other's board state.
pub fn exploitability(self: *Solver, root: *Node) !f32 {
    var br_p1: [NUM_HANDS]f32 = undefined;
    var br_p2: [NUM_HANDS]f32 = undefined;

    var board_a: BoardContext = self.board_ctx;
    var board_b: BoardContext = self.board_ctx;
    var ctx_a = SolveContext.initOnBoardContext(self, &board_a);
    var ctx_b = SolveContext.initOnBoardContext(self, &board_b);

    const job_a = BrJob{ .ctx = &ctx_a, .root = root, .br_isp1 = true, .out_cfv = &br_p1 };
    const job_b = BrJob{ .ctx = &ctx_b, .root = root, .br_isp1 = false, .out_cfv = &br_p2 };

    const thread_a = try std.Thread.spawn(.{}, BrJob.run, .{job_a});
    const thread_b = try std.Thread.spawn(.{}, BrJob.run, .{job_b});
    thread_a.join();
    thread_b.join();

    var v_p1: f32 = 0;
    var v_p2: f32 = 0;
    var i: usize = 0;
    while (i < NUM_HANDS) : (i += 1) {
        v_p1 += self.p1_reach[i] * br_p1[i];
        v_p2 += self.p2_reach[i] * br_p2[i];
    }
    return v_p1 + v_p2;
}

test "snapshotBoard / restoreBoard round-trips state through a different board" {
    const allocator = std.testing.allocator;

    const board_a = [5]Card{
        card_mod.makeCard(12, 0),
        card_mod.makeCard(11, 0),
        card_mod.makeCard(10, 0),
        card_mod.makeCard(9, 0),
        card_mod.makeCard(8, 0),
    };
    const board_b = [5]Card{
        card_mod.makeCard(2, 1),
        card_mod.makeCard(5, 2),
        card_mod.makeCard(7, 3),
        card_mod.makeCard(9, 1),
        card_mod.makeCard(11, 2),
    };

    var p1 = try range_mod.Range.initEmpty(allocator, 0);
    defer p1.deinit(allocator);
    var p2 = try range_mod.Range.initEmpty(allocator, 0);
    defer p2.deinit(allocator);

    var solver = try Solver.init(std.testing.io, board_a, &p1, &p2, 1000, 1000, 100);
    defer solver.deinit();

    var snap: BoardContext = undefined;
    solver.snapshotBoard(&snap);

    // Capture board_a's per-hand strength for a specific unblocked hand.
    const ht = HandTable.init();
    const probe_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(0, 1), card_mod.makeCard(0, 2))).?;
    const strength_a = solver.board_ctx.hand_strengths[probe_idx];
    const rank_a = solver.board_ctx.rank_map[probe_idx];

    solver.reinitForBoard(board_b);
    // After reinit, strengths should reflect board_b — almost certainly different.
    try std.testing.expect(solver.board_ctx.hand_strengths[probe_idx] != strength_a or solver.board_ctx.rank_map[probe_idx] != rank_a);

    solver.restoreBoard(&snap);

    // After restore, everything that depends on the board is back.
    try std.testing.expectEqual(strength_a, solver.board_ctx.hand_strengths[probe_idx]);
    try std.testing.expectEqual(rank_a, solver.board_ctx.rank_map[probe_idx]);
    for (board_a, solver.board_ctx.board) |expected, actual| try std.testing.expectEqual(expected, actual);
}

test "two SolveContexts on separate BoardContexts isolate board state" {
    const allocator = std.testing.allocator;

    const board_a = [5]Card{
        card_mod.makeCard(12, 0),
        card_mod.makeCard(11, 0),
        card_mod.makeCard(10, 0),
        card_mod.makeCard(9, 0),
        card_mod.makeCard(8, 0),
    };
    const board_b = [5]Card{
        card_mod.makeCard(2, 1),
        card_mod.makeCard(5, 2),
        card_mod.makeCard(7, 3),
        card_mod.makeCard(9, 1),
        card_mod.makeCard(11, 2),
    };

    var p1 = try range_mod.Range.initEmpty(allocator, 0);
    defer p1.deinit(allocator);
    var p2 = try range_mod.Range.initEmpty(allocator, 0);
    defer p2.deinit(allocator);

    var solver = try Solver.init(std.testing.io, board_a, &p1, &p2, 1000, 1000, 100);
    defer solver.deinit();

    // A separate BoardContext owned by "worker B" — same Solver, independent
    // board state. This is the shape parallel workers will take.
    var worker_b_board: BoardContext = BoardContext.compute(&solver.evaluator, &solver.hand_table, board_a);

    const ctx_a = SolveContext.initOnSolver(&solver);
    var ctx_b = SolveContext.initOnBoardContext(&solver, &worker_b_board);

    const ht = HandTable.init();
    const probe_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(0, 1), card_mod.makeCard(0, 2))).?;
    const strength_before = solver.board_ctx.hand_strengths[probe_idx];

    // Worker B mutates its own board_ctx. Worker A's board_ctx (== solver's)
    // must remain untouched.
    ctx_b.reinitForBoard(board_b);
    try std.testing.expectEqual(strength_before, solver.board_ctx.hand_strengths[probe_idx]);
    try std.testing.expectEqual(strength_before, ctx_a.board_ctx.hand_strengths[probe_idx]);
    try std.testing.expect(worker_b_board.hand_strengths[probe_idx] != strength_before);
    try std.testing.expect(ctx_b.board_ctx.hand_strengths[probe_idx] != strength_before);
    for (board_b, worker_b_board.board) |expected, actual| try std.testing.expectEqual(expected, actual);

    // Push/pop on worker B must not leak into worker A's snapshot stack.
    ctx_b.pushSnapshot();
    ctx_b.reinitForBoard(board_a);
    try std.testing.expectEqual(strength_before, worker_b_board.hand_strengths[probe_idx]);
    try std.testing.expectEqual(@as(u8, 0), ctx_a.chance_depth);
    ctx_b.popSnapshot();
    try std.testing.expect(worker_b_board.hand_strengths[probe_idx] != strength_before);
}

test "Solver.init: blocker mask, strengths, densified ranges" {
    const allocator = std.testing.allocator;

    // Royal-flush board on spades.
    const board = [5]Card{
        card_mod.makeCard(12, 0),
        card_mod.makeCard(11, 0),
        card_mod.makeCard(10, 0),
        card_mod.makeCard(9, 0),
        card_mod.makeCard(8, 0),
    };

    const ht = HandTable.init();
    // A hand entirely off-board (2h2d) and a hand containing a board card (As + 2h).
    const safe_hand = range_mod.Hand.init(card_mod.makeCard(0, 1), card_mod.makeCard(0, 2));
    const blocked_hand = range_mod.Hand.init(card_mod.makeCard(12, 0), card_mod.makeCard(0, 1));
    const safe_idx = ht.getIndex(safe_hand).?;
    const blocked_idx = ht.getIndex(blocked_hand).?;

    // p1 puts weight on both hands; the blocked one must be zeroed in p1_reach.
    var p1 = try Range.initEmpty(allocator, 2);
    defer p1.deinit(allocator);
    p1.active_indices[0] = safe_idx;
    p1.probs[0] = 0.7;
    p1.active_indices[1] = blocked_idx;
    p1.probs[1] = 0.3;

    var p2 = try Range.initEmpty(allocator, 0);
    defer p2.deinit(allocator);

    var solver = try Solver.init(std.testing.io, board, &p1, &p2, 1000, 1000, 100);
    defer solver.deinit();

    // Total hands collide-free with 5 board cards = C(47,2) = 1081 → 1326 - 1081 = 245 blocked.
    var blocked_count: usize = 0;
    for (solver.board_ctx.blocked) |b| {
        if (b) blocked_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 245), blocked_count);

    try std.testing.expect(solver.board_ctx.blocked[blocked_idx]);
    try std.testing.expect(!solver.board_ctx.blocked[safe_idx]);
    try std.testing.expectEqual(@as(u32, 0), solver.board_ctx.hand_strengths[blocked_idx]);
    try std.testing.expect(solver.board_ctx.hand_strengths[safe_idx] > 0);

    try std.testing.expectEqual(@as(f32, 0.7), solver.p1_reach[safe_idx]);
    try std.testing.expectEqual(@as(f32, 0), solver.p1_reach[blocked_idx]);
}

test "terminalFold: p1 folds, payoff is folder's effective contribution" {
    const allocator = std.testing.allocator;

    const board = [5]Card{
        card_mod.makeCard(12, 0),
        card_mod.makeCard(11, 0),
        card_mod.makeCard(10, 0),
        card_mod.makeCard(9, 0),
        card_mod.makeCard(8, 0),
    };

    var p1 = try Range.initEmpty(allocator, 0);
    defer p1.deinit(allocator);
    var p2 = try Range.initEmpty(allocator, 0);
    defer p2.deinit(allocator);

    var solver = try Solver.init(std.testing.io, board, &p1, &p2, 1000, 1000, 0);
    defer solver.deinit();

    // p1 holds 2h2d, p2 holds 3h3d — compatible, both unblocked.
    const ht = HandTable.init();
    const p1_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(0, 1), card_mod.makeCard(0, 2))).?;
    const p2_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(1, 1), card_mod.makeCard(1, 2))).?;
    solver.p1_reach[p1_idx] = 1.0;
    solver.p2_reach[p2_idx] = 1.0;

    // Sequence: p1 bets 50, p2 raises to 150, p1 folds. Pot=200, stacks=(950, 850).
    const edge = Edge{
        .action = .FOLD,
        .amount = 200,
        .stack1 = 950,
        .stack2 = 850,
        .child = null,
    };

    var cfv_p1: [NUM_HANDS]f32 = undefined;
    var cfv_p2: [NUM_HANDS]f32 = undefined;
    solver.terminalFold(&edge, true, &solver.p1_reach, &solver.p2_reach, &cfv_p1, &cfv_p2);

    // p1's effective contribution = 50. p1 loses 50 against any compatible p2 hand.
    try std.testing.expectEqual(@as(f32, -50), cfv_p1[p1_idx]);
    try std.testing.expectEqual(@as(f32, 50), cfv_p2[p2_idx]);
}

test "terminalShowdown: AA beats KK on a junk board" {
    const allocator = std.testing.allocator;

    // 7c 8h 2d 5c 4s — no pairs, no flush draws, no straights for AA/KK.
    const board = [5]Card{
        card_mod.makeCard(5, 3),
        card_mod.makeCard(6, 1),
        card_mod.makeCard(0, 2),
        card_mod.makeCard(3, 3),
        card_mod.makeCard(2, 0),
    };

    var p1 = try Range.initEmpty(allocator, 0);
    defer p1.deinit(allocator);
    var p2 = try Range.initEmpty(allocator, 0);
    defer p2.deinit(allocator);

    var solver = try Solver.init(std.testing.io, board, &p1, &p2, 1000, 1000, 0);
    defer solver.deinit();

    const ht = HandTable.init();
    const aa_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 0), card_mod.makeCard(12, 1))).?;
    const kk_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(11, 3), card_mod.makeCard(11, 2))).?;
    solver.p1_reach[aa_idx] = 1.0;
    solver.p2_reach[kk_idx] = 1.0;

    // Each contributed 100 since root. Pot = 200, half = 100.
    const edge = Edge{
        .action = .CALL,
        .amount = 200,
        .stack1 = 900,
        .stack2 = 900,
        .child = null,
    };

    var cfv_p1: [NUM_HANDS]f32 = undefined;
    var cfv_p2: [NUM_HANDS]f32 = undefined;
    solver.terminalShowdown(&edge, &solver.p1_reach, &solver.p2_reach, &cfv_p1, &cfv_p2);

    try std.testing.expectEqual(@as(f32, 100), cfv_p1[aa_idx]);
    try std.testing.expectEqual(@as(f32, -100), cfv_p2[kk_idx]);
}

test "chance runout counts condition on each private hand" {
    const ht = HandTable.init();
    const aa = ht.getHand(ht.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 0), card_mod.makeCard(12, 1))).?);
    const board_flop = [5]Card{
        card_mod.makeCard(5, 3),
        card_mod.makeCard(6, 1),
        card_mod.makeCard(0, 2),
        0,
        0,
    };
    const board_turn = [5]Card{
        card_mod.makeCard(5, 3),
        card_mod.makeCard(6, 1),
        card_mod.makeCard(0, 2),
        card_mod.makeCard(3, 3),
        0,
    };
    const blocked = range_mod.Hand.init(card_mod.makeCard(5, 3), card_mod.makeCard(12, 0));

    try std.testing.expectEqual(@as(u32, 49), publicChanceCardCount(board_flop));
    try std.testing.expectEqual(@as(u32, 48), publicChanceCardCount(board_turn));
    // Flop leaves now enumerate unordered (turn, river) pairs, so the
    // denominator is C(47, 2) = 47*46/2 = 1081 instead of 47*46 = 2162.
    try std.testing.expectEqual(@as(u32, 47 * 46 / 2), legalRunoutCount(board_flop, aa, 2));
    try std.testing.expectEqual(@as(u32, 46), legalRunoutCount(board_turn, aa, 1));
    try std.testing.expectEqual(@as(u32, 0), legalRunoutCount(board_turn, blocked, 1));
}

test "Solver.solve: AA vs KK river — p1 always wins ~+25 EV" {
    var da = std.heap.DebugAllocator(.{}){};
    defer _ = da.deinit();
    const temp_allocator = da.allocator();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // River start: pot=50, stacks=100/100. Bet ladder: 25, 50 from 50% / 100%.
    var root_state = gamestate_mod.GameState.init(.RIVER, true, 50, 100, 100);
    var arr = std.ArrayList(Edge).empty;
    defer arr.deinit(temp_allocator);
    try node_mod.buildTree(&root_state, &arr, arena_allocator, temp_allocator, NUM_HANDS, NUM_HANDS);
    const root = arr.items[0].child.?;

    // Junk board so AA and KK each make only a pair, no straights/flushes.
    const board = [5]Card{
        card_mod.makeCard(5, 3),
        card_mod.makeCard(6, 1),
        card_mod.makeCard(0, 2),
        card_mod.makeCard(3, 3),
        card_mod.makeCard(2, 0),
    };

    const ht = HandTable.init();
    const aa_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 0), card_mod.makeCard(12, 1))).?;
    const kk_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(11, 3), card_mod.makeCard(11, 2))).?;

    var p1 = try Range.initEmpty(temp_allocator, 1);
    defer p1.deinit(temp_allocator);
    p1.active_indices[0] = aa_idx;
    p1.probs[0] = 1.0;
    var p2 = try Range.initEmpty(temp_allocator, 1);
    defer p2.deinit(temp_allocator);
    p2.active_indices[0] = kk_idx;
    p2.probs[0] = 1.0;

    var solver = try Solver.init(std.testing.io, board, &p1, &p2, 100, 100, 50);
    defer solver.deinit();

    var cfv_p1: [NUM_HANDS]f32 = undefined;
    var cfv_p2: [NUM_HANDS]f32 = undefined;
    var prng = std.Random.DefaultPrng.init(42);
    try solve(&solver, temp_allocator, root, 200, prng.random(), &cfv_p1, &cfv_p2);

    // AA always beats KK on this board. At NE p2 folds to any p1 bet and p1
    // can also just check it down — either way p1's root CFV is exactly +25
    // (half of the unraised pot OR the folder's effective contribution).
    try std.testing.expectApproxEqAbs(@as(f32, 25), cfv_p1[aa_idx], 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, -25), cfv_p2[kk_idx], 0.5);

    // CFR+ with linear averaging converges much faster than vanilla CFR.
    // Vanilla baseline landed near 0.75 after 200 iters; CFR+ comes in around
    // 0.015 in the same budget.
    const expl = try exploitability(&solver, root);
    try std.testing.expect(@abs(expl) < 0.05);
}

test "averageStrategy: KK folds to p1's bet on AA-vs-KK river" {
    var da = std.heap.DebugAllocator(.{}){};
    defer _ = da.deinit();
    const temp_allocator = da.allocator();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var root_state = gamestate_mod.GameState.init(.RIVER, true, 50, 100, 100);
    var arr = std.ArrayList(Edge).empty;
    defer arr.deinit(temp_allocator);
    try node_mod.buildTree(&root_state, &arr, arena_allocator, temp_allocator, NUM_HANDS, NUM_HANDS);
    const root = arr.items[0].child.?;

    const board = [5]Card{
        card_mod.makeCard(5, 3),
        card_mod.makeCard(6, 1),
        card_mod.makeCard(0, 2),
        card_mod.makeCard(3, 3),
        card_mod.makeCard(2, 0),
    };

    const ht = HandTable.init();
    const aa_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 0), card_mod.makeCard(12, 1))).?;
    const kk_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(11, 3), card_mod.makeCard(11, 2))).?;

    var p1 = try range_mod.Range.initEmpty(temp_allocator, 1);
    defer p1.deinit(temp_allocator);
    p1.active_indices[0] = aa_idx;
    p1.probs[0] = 1.0;
    var p2 = try range_mod.Range.initEmpty(temp_allocator, 1);
    defer p2.deinit(temp_allocator);
    p2.active_indices[0] = kk_idx;
    p2.probs[0] = 1.0;

    var solver = try Solver.init(std.testing.io, board, &p1, &p2, 100, 100, 50);
    defer solver.deinit();

    var cfv_p1: [NUM_HANDS]f32 = undefined;
    var cfv_p2: [NUM_HANDS]f32 = undefined;
    var prng = std.Random.DefaultPrng.init(42);
    try solve(&solver, temp_allocator, root, 500, prng.random(), &cfv_p1, &cfv_p2);

    // Find a p1 BET edge at the root; descend into p2's facing-bet node.
    var bet_edge: ?*Edge = null;
    for (root.edges) |*e| {
        if (e.action == .BET or e.action == .ALLIN) {
            bet_edge = e;
            break;
        }
    }
    const p2_node = bet_edge.?.child.?;
    try std.testing.expect(!p2_node.is_chance);
    try std.testing.expect(!p2_node.isp1);

    const n_actions = p2_node.edges.len;
    const out = try temp_allocator.alloc(f32, n_actions * NUM_HANDS);
    defer temp_allocator.free(out);
    averageStrategy(p2_node, out);

    // Locate the FOLD action index for p2's response.
    var fold_action: ?usize = null;
    for (p2_node.edges, 0..) |e, idx| {
        if (e.action == .FOLD) {
            fold_action = idx;
            break;
        }
    }
    const fa = fold_action.?;
    // KK must fold ~100% — it can never beat AA on a dry low board.
    try std.testing.expect(out[fa * NUM_HANDS + kk_idx] > 0.95);

    // Sanity: row sums to ~1 for the only hand we care about.
    var row_sum: f32 = 0;
    for (0..n_actions) |a| row_sum += out[a * NUM_HANDS + kk_idx];
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), row_sum, 1e-4);
}

test "Solver.solve: polarized vs condensed river" {
    var da = std.heap.DebugAllocator(.{}){};
    defer _ = da.deinit();
    const temp_allocator = da.allocator();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // River: pot=100, stacks=500/500.
    var root_state = gamestate_mod.GameState.init(.RIVER, true, 100, 500, 500);
    var arr = std.ArrayList(Edge).empty;
    defer arr.deinit(temp_allocator);
    try node_mod.buildTree(&root_state, &arr, arena_allocator, temp_allocator, NUM_HANDS, NUM_HANDS);
    const root = arr.items[0].child.?;

    // Board: As Ks 2h 3d 7c (Dry, high cards favored)
    const board = [5]Card{
        card_mod.makeCard(12, 0),
        card_mod.makeCard(11, 0),
        card_mod.makeCard(0, 1),
        card_mod.makeCard(1, 2),
        card_mod.makeCard(5, 3),
    };

    const ht = HandTable.init();

    // P1 (Polarized): AA, KK (Nuts) and some 72o (Air)
    // P2 (Condensed): AQ, AJ, AT (Middling strength)
    var p1 = try Range.initEmpty(temp_allocator, 3);
    defer p1.deinit(temp_allocator);
    p1.active_indices[0] = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 1), card_mod.makeCard(12, 2))).?; // AA
    p1.active_indices[1] = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(11, 1), card_mod.makeCard(11, 2))).?; // KK
    p1.active_indices[2] = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(5, 0), card_mod.makeCard(0, 3))).?; // 7s2c
    p1.probs[0] = 0.2;
    p1.probs[1] = 0.2;
    p1.probs[2] = 0.6;
    p1.normalize();

    var p2 = try Range.initEmpty(temp_allocator, 3);
    defer p2.deinit(temp_allocator);
    p2.active_indices[0] = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 1), card_mod.makeCard(10, 2))).?; // AQ
    p2.active_indices[1] = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 1), card_mod.makeCard(9, 2))).?; // AJ
    p2.active_indices[2] = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 1), card_mod.makeCard(8, 2))).?; // AT
    p2.probs[0] = 0.33;
    p2.probs[1] = 0.33;
    p2.probs[2] = 0.34;
    p2.normalize();

    var solver = try Solver.init(std.testing.io, board, &p1, &p2, 500, 500, 100);
    defer solver.deinit();

    var cfv_p1: [NUM_HANDS]f32 = undefined;
    var cfv_p2: [NUM_HANDS]f32 = undefined;
    var prng = std.Random.DefaultPrng.init(42);
    try solve(&solver, temp_allocator, root, 200, prng.random(), &cfv_p1, &cfv_p2);

    const expl = try exploitability(&solver, root);
    // Vanilla CFR baseline left this in the single-digit range; CFR+ with
    // linear averaging brings it under 0.05 in the same 200-iter budget.
    try std.testing.expect(expl < 0.05);
}

test "Solver.solve: turn-start AA vs KK — chance node enumeration" {
    var da = std.heap.DebugAllocator(.{}){};
    defer _ = da.deinit();
    const temp_allocator = da.allocator();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Turn start: pot=50, stacks=100/100.
    var root_state = gamestate_mod.GameState.init(.TURN, true, 50, 100, 100);
    var arr = std.ArrayList(Edge).empty;
    defer arr.deinit(temp_allocator);
    // This tree will have chance nodes at check-check or bet-call transitions.
    try node_mod.buildTree(&root_state, &arr, arena_allocator, temp_allocator, NUM_HANDS, NUM_HANDS);
    const root = arr.items[0].child.?;

    // Turn board (river card is 0).
    const board = [5]Card{
        card_mod.makeCard(5, 3),
        card_mod.makeCard(6, 1),
        card_mod.makeCard(0, 2),
        card_mod.makeCard(3, 3),
        0,
    };

    const ht = HandTable.init();
    const aa_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 0), card_mod.makeCard(12, 1))).?;
    const kk_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(11, 3), card_mod.makeCard(11, 2))).?;

    var p1 = try Range.initEmpty(temp_allocator, 1);
    defer p1.deinit(temp_allocator);
    p1.active_indices[0] = aa_idx;
    p1.probs[0] = 1.0;
    var p2 = try Range.initEmpty(temp_allocator, 1);
    defer p2.deinit(temp_allocator);
    p2.active_indices[0] = kk_idx;
    p2.probs[0] = 1.0;

    var solver = try Solver.init(std.testing.io, board, &p1, &p2, 100, 100, 50);
    defer solver.deinit();

    var cfv_p1: [NUM_HANDS]f32 = undefined;
    var cfv_p2: [NUM_HANDS]f32 = undefined;

    // Just run a few iterations to verify it doesn't crash and handles chance.
    var prng = std.Random.DefaultPrng.init(42);
    try solve(&solver, temp_allocator, root, 10, prng.random(), &cfv_p1, &cfv_p2);

    // AA still mostly beats KK, though some river cards could change that.
    // We just want to see it run through the chance nodes.
    try std.testing.expect(cfv_p1[aa_idx] > 0);
}

test "walk: truncated chance leaf uses all-in equity evaluator" {
    const allocator = std.testing.allocator;
    const board = [5]Card{
        card_mod.makeCard(5, 3),
        card_mod.makeCard(6, 1),
        card_mod.makeCard(0, 2),
        card_mod.makeCard(3, 3),
        0,
    };

    const ht = HandTable.init();
    const aa_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 0), card_mod.makeCard(12, 1))).?;
    const kk_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(11, 3), card_mod.makeCard(11, 2))).?;

    var p1 = try Range.initEmpty(allocator, 1);
    defer p1.deinit(allocator);
    p1.active_indices[0] = aa_idx;
    p1.probs[0] = 1.0;
    var p2 = try Range.initEmpty(allocator, 1);
    defer p2.deinit(allocator);
    p2.active_indices[0] = kk_idx;
    p2.probs[0] = 1.0;

    var solver = try Solver.init(std.testing.io, board, &p1, &p2, 100, 100, 50);
    defer solver.deinit();

    var leaf_edges = [_]Edge{.{
        .action = .CHANCE,
        .amount = 50,
        .stack1 = 100,
        .stack2 = 100,
        .child = null,
    }};
    var leaf_node = Node{
        .is_chance = true,
        .is_leaf = true,
        .isp1 = true,
        .id = node_mod.UNASSIGNED_ID,
        .regrets = &.{},
        .strategy_sum = &.{},
        .edges = leaf_edges[0..],
    };

    var cfv_p1: [NUM_HANDS]f32 = undefined;
    var cfv_p2: [NUM_HANDS]f32 = undefined;
    var prng = std.Random.DefaultPrng.init(42);
    var ctx = SolveContext.initOnSolver(&solver);
    walk(&ctx, &leaf_node, &solver.p1_reach, &solver.p2_reach, &cfv_p1, &cfv_p2, prng.random(), 1.0, null);

    const expected = @as(f32, 125.0) * @as(f32, 40.0) / @as(f32, 46.0);
    try std.testing.expectApproxEqAbs(expected, cfv_p1[aa_idx], 1e-3);
    try std.testing.expectApproxEqAbs(-expected, cfv_p2[kk_idx], 1e-3);
}

test "allInEquityLeaf: full 5-card board matches terminalShowdown" {
    const allocator = std.testing.allocator;

    // 7c 8h 2d 5c 4s — complete board, no draws relevant.
    const board = [5]Card{
        card_mod.makeCard(5, 3),
        card_mod.makeCard(6, 1),
        card_mod.makeCard(0, 2),
        card_mod.makeCard(3, 3),
        card_mod.makeCard(2, 0),
    };

    var p1 = try Range.initEmpty(allocator, 0);
    defer p1.deinit(allocator);
    var p2 = try Range.initEmpty(allocator, 0);
    defer p2.deinit(allocator);

    var solver = try Solver.init(std.testing.io, board, &p1, &p2, 1000, 1000, 0);
    defer solver.deinit();

    const ht = HandTable.init();
    const aa_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 0), card_mod.makeCard(12, 1))).?;
    const kk_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(11, 3), card_mod.makeCard(11, 2))).?;
    solver.p1_reach[aa_idx] = 1.0;
    solver.p2_reach[kk_idx] = 1.0;

    // edge.amount=200, stacks=0 → synthetic pot stays at 200, matching terminalShowdown.
    const edge = Edge{
        .action = .CALL,
        .amount = 200,
        .stack1 = 0,
        .stack2 = 0,
        .child = null,
    };

    var leaf_p1: [NUM_HANDS]f32 = undefined;
    var leaf_p2: [NUM_HANDS]f32 = undefined;
    solver.allInEquityLeaf(&edge, &solver.p1_reach, &solver.p2_reach, &leaf_p1, &leaf_p2);

    var ref_p1: [NUM_HANDS]f32 = undefined;
    var ref_p2: [NUM_HANDS]f32 = undefined;
    solver.terminalShowdown(&edge, &solver.p1_reach, &solver.p2_reach, &ref_p1, &ref_p2);

    // The leaf reduces to a single showdown on a full board, so the two paths
    // must agree exactly on the hands we care about.
    try std.testing.expectEqual(ref_p1[aa_idx], leaf_p1[aa_idx]);
    try std.testing.expectEqual(ref_p2[kk_idx], leaf_p2[kk_idx]);
}

test "allInEquityLeaf: flop chance — AA dominates KK and CFVs are zero-sum" {
    const allocator = std.testing.allocator;

    // 7c 8h 2d, board cards 4 & 5 unset → flop-chance entry point.
    const board = [5]Card{
        card_mod.makeCard(5, 3),
        card_mod.makeCard(6, 1),
        card_mod.makeCard(0, 2),
        0,
        0,
    };

    var p1 = try Range.initEmpty(allocator, 0);
    defer p1.deinit(allocator);
    var p2 = try Range.initEmpty(allocator, 0);
    defer p2.deinit(allocator);

    var solver = try Solver.init(std.testing.io, board, &p1, &p2, 100, 100, 50);
    defer solver.deinit();

    const ht = HandTable.init();
    const aa_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 0), card_mod.makeCard(12, 1))).?;
    const kk_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(11, 3), card_mod.makeCard(11, 2))).?;
    solver.p1_reach[aa_idx] = 1.0;
    solver.p2_reach[kk_idx] = 1.0;

    // Pot 50, both with 100 left → synthetic shove pot = 250, half = 125.
    const edge = Edge{
        .action = .CHANCE,
        .amount = 50,
        .stack1 = 100,
        .stack2 = 100,
        .child = null,
    };

    var leaf_p1: [NUM_HANDS]f32 = undefined;
    var leaf_p2: [NUM_HANDS]f32 = undefined;
    solver.allInEquityLeaf(&edge, &solver.p1_reach, &solver.p2_reach, &leaf_p1, &leaf_p2);

    // AA is a heavy favorite on a dry low rainbow flop vs KK. Chance averaging
    // is per private hand, so runouts hitting AA are excluded from AA's
    // denominator while runouts hitting KK contribute zero opponent mass.
    try std.testing.expect(leaf_p1[aa_idx] > 60.0);

    // With symmetric singleton ranges, both tracked hands have the same number
    // of legal runouts and the same impossible-opponent-card exclusions.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), leaf_p1[aa_idx] + leaf_p2[kk_idx], 1e-3);

    // Blocked hands stay at zero. Pick a hand using one of the flop cards.
    const flop_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(5, 3), card_mod.makeCard(10, 0))).?;
    try std.testing.expectEqual(@as(f32, 0.0), leaf_p1[flop_idx]);
}

test "allInEquityLeaf: turn chance — river-only enumeration runs and zero-sum holds" {
    const allocator = std.testing.allocator;

    // 7c 8h 2d 5c → turn complete, river pending.
    const board = [5]Card{
        card_mod.makeCard(5, 3),
        card_mod.makeCard(6, 1),
        card_mod.makeCard(0, 2),
        card_mod.makeCard(3, 3),
        0,
    };

    var p1 = try Range.initEmpty(allocator, 0);
    defer p1.deinit(allocator);
    var p2 = try Range.initEmpty(allocator, 0);
    defer p2.deinit(allocator);

    var solver = try Solver.init(std.testing.io, board, &p1, &p2, 100, 100, 50);
    defer solver.deinit();

    const ht = HandTable.init();
    const aa_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 0), card_mod.makeCard(12, 1))).?;
    const kk_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(11, 3), card_mod.makeCard(11, 2))).?;
    solver.p1_reach[aa_idx] = 1.0;
    solver.p2_reach[kk_idx] = 1.0;

    const edge = Edge{
        .action = .CHANCE,
        .amount = 50,
        .stack1 = 100,
        .stack2 = 100,
        .child = null,
    };

    var leaf_p1: [NUM_HANDS]f32 = undefined;
    var leaf_p2: [NUM_HANDS]f32 = undefined;
    solver.allInEquityLeaf(&edge, &solver.p1_reach, &solver.p2_reach, &leaf_p1, &leaf_p2);

    const expected = @as(f32, 125.0) * @as(f32, 40.0) / @as(f32, 46.0);
    try std.testing.expectApproxEqAbs(expected, leaf_p1[aa_idx], 1e-3);
    try std.testing.expectApproxEqAbs(-expected, leaf_p2[kk_idx], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), leaf_p1[aa_idx] + leaf_p2[kk_idx], 1e-3);
}

test "brWalk: chance averaging uses per-hand legal river count" {
    const allocator = std.testing.allocator;

    const board = [5]Card{
        card_mod.makeCard(5, 3),
        card_mod.makeCard(6, 1),
        card_mod.makeCard(0, 2),
        card_mod.makeCard(3, 3),
        0,
    };

    var p1 = try Range.initEmpty(allocator, 0);
    defer p1.deinit(allocator);
    var p2 = try Range.initEmpty(allocator, 0);
    defer p2.deinit(allocator);

    var solver = try Solver.init(std.testing.io, board, &p1, &p2, 100, 100, 50);
    defer solver.deinit();

    const ht = HandTable.init();
    const aa_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 0), card_mod.makeCard(12, 1))).?;
    const kk_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(11, 3), card_mod.makeCard(11, 2))).?;
    solver.p1_reach[aa_idx] = 1.0;
    solver.p2_reach[kk_idx] = 1.0;

    var chance_edges = [_]Edge{.{
        .action = .CHANCE,
        .amount = 250,
        .stack1 = 0,
        .stack2 = 0,
        .child = null,
    }};
    var chance_node = Node{
        .is_chance = true,
        .is_leaf = false,
        .isp1 = true,
        .id = node_mod.UNASSIGNED_ID,
        .regrets = &.{},
        .strategy_sum = &.{},
        .edges = chance_edges[0..],
    };

    var cfv: [NUM_HANDS]f32 = undefined;
    var ctx = SolveContext.initOnSolver(&solver);
    brWalk(&ctx, &chance_node, &solver.p1_reach, &solver.p2_reach, true, &cfv);

    const expected = @as(f32, 125.0) * @as(f32, 40.0) / @as(f32, 46.0);
    try std.testing.expectApproxEqAbs(expected, cfv[aa_idx], 1e-3);
}

test "verification: all-in equity leaf matches exact full-runout chance tree" {
    const allocator = std.testing.allocator;

    // Flop entry: the exact tree enumerates turn and river chance nodes after
    // an all-in call; the truncated tree replaces that with allInEquityLeaf.
    const board = [5]Card{
        card_mod.makeCard(5, 3),
        card_mod.makeCard(6, 1),
        card_mod.makeCard(0, 2),
        0,
        0,
    };

    var p1 = try Range.initEmpty(allocator, 0);
    defer p1.deinit(allocator);
    var p2 = try Range.initEmpty(allocator, 0);
    defer p2.deinit(allocator);

    var solver = try Solver.init(std.testing.io, board, &p1, &p2, 100, 100, 50);
    defer solver.deinit();

    const ht = HandTable.init();
    const aa_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 0), card_mod.makeCard(12, 1))).?;
    const kk_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(11, 3), card_mod.makeCard(11, 2))).?;
    solver.p1_reach[aa_idx] = 1.0;
    solver.p2_reach[kk_idx] = 1.0;

    var river_edges = [_]Edge{.{
        .action = .CHANCE,
        .amount = 250,
        .stack1 = 0,
        .stack2 = 0,
        .child = null,
    }};
    var river_chance = Node{
        .is_chance = true,
        .is_leaf = false,
        .isp1 = true,
        .id = node_mod.UNASSIGNED_ID,
        .regrets = &.{},
        .strategy_sum = &.{},
        .edges = river_edges[0..],
    };
    var turn_edges = [_]Edge{.{
        .action = .CHANCE,
        .amount = 250,
        .stack1 = 0,
        .stack2 = 0,
        .child = &river_chance,
    }};
    var turn_chance = Node{
        .is_chance = true,
        .is_leaf = false,
        .isp1 = true,
        .id = node_mod.UNASSIGNED_ID,
        .regrets = &.{},
        .strategy_sum = &.{},
        .edges = turn_edges[0..],
    };

    var exact_p1: [NUM_HANDS]f32 = undefined;
    var exact_p2: [NUM_HANDS]f32 = undefined;
    var ctx = SolveContext.initOnSolver(&solver);
    brWalk(&ctx, &turn_chance, &solver.p1_reach, &solver.p2_reach, true, &exact_p1);
    brWalk(&ctx, &turn_chance, &solver.p1_reach, &solver.p2_reach, false, &exact_p2);

    const leaf_edge = Edge{
        .action = .CHANCE,
        .amount = 250,
        .stack1 = 0,
        .stack2 = 0,
        .child = null,
    };
    var leaf_p1: [NUM_HANDS]f32 = undefined;
    var leaf_p2: [NUM_HANDS]f32 = undefined;
    solver.allInEquityLeaf(&leaf_edge, &solver.p1_reach, &solver.p2_reach, &leaf_p1, &leaf_p2);

    try std.testing.expectApproxEqAbs(exact_p1[aa_idx], leaf_p1[aa_idx], 1e-3);
    try std.testing.expectApproxEqAbs(exact_p2[kk_idx], leaf_p2[kk_idx], 1e-3);
}

test "allInEquityLeaf: cached and un-cached paths produce identical CFVs" {
    // Both flop and turn roots: build the runout cache, take a full vector
    // snapshot of `allInEquityLeaf`, then tear the cache down and re-run.
    // Cached and un-cached paths must produce bit-identical CFVs over all
    // 1326 hands — the cache is a pure optimization with no behavioral side
    // effects.
    const allocator = std.testing.allocator;

    const flop_board = [5]Card{
        card_mod.makeCard(5, 3),
        card_mod.makeCard(6, 1),
        card_mod.makeCard(0, 2),
        0,
        0,
    };
    const turn_board = [5]Card{
        card_mod.makeCard(5, 3),
        card_mod.makeCard(6, 1),
        card_mod.makeCard(0, 2),
        card_mod.makeCard(10, 0),
        0,
    };

    inline for ([_][5]Card{ flop_board, turn_board }) |board| {
        var p1 = try Range.initEmpty(allocator, 0);
        defer p1.deinit(allocator);
        var p2 = try Range.initEmpty(allocator, 0);
        defer p2.deinit(allocator);

        var solver = try Solver.init(std.testing.io, board, &p1, &p2, 100, 100, 50);
        defer solver.deinit();

        const ht = HandTable.init();
        const aa_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 0), card_mod.makeCard(12, 1))).?;
        const kk_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(11, 3), card_mod.makeCard(11, 2))).?;
        // Use a multi-hand range to exercise the masking + showdown path
        // across many runouts, not just two singletons.
        solver.p1_reach[aa_idx] = 1.0;
        solver.p2_reach[kk_idx] = 1.0;
        const qq_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(10, 0), card_mod.makeCard(10, 1))).?;
        const jj_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(9, 0), card_mod.makeCard(9, 1))).?;
        solver.p1_reach[qq_idx] = 0.5;
        solver.p2_reach[jj_idx] = 0.7;

        const edge = Edge{
            .action = .CHANCE,
            .amount = 50,
            .stack1 = 100,
            .stack2 = 100,
            .child = null,
        };

        var uncached_p1: [NUM_HANDS]f32 = undefined;
        var uncached_p2: [NUM_HANDS]f32 = undefined;
        solver.allInEquityLeaf(&edge, &solver.p1_reach, &solver.p2_reach, &uncached_p1, &uncached_p2);

        try solver.buildRunoutCacheIfNeeded(allocator);
        try std.testing.expect(solver.runout_cache != null);

        var cached_p1: [NUM_HANDS]f32 = undefined;
        var cached_p2: [NUM_HANDS]f32 = undefined;
        solver.allInEquityLeaf(&edge, &solver.p1_reach, &solver.p2_reach, &cached_p1, &cached_p2);

        // Bit-identical: both paths visit the same set of unordered runouts,
        // both call computeShowdownCFV with the same operands in the same
        // order. Any drift here means the cache and the slow path disagree
        // and one of them is wrong.
        for (0..NUM_HANDS) |i| {
            try std.testing.expectEqual(uncached_p1[i], cached_p1[i]);
            try std.testing.expectEqual(uncached_p2[i], cached_p2[i]);
        }
    }
}

test "Solver.solve: pool delivers bit-identical results across runs with same seed" {
    // Regression for the persistent worker pool: two independent solves with
    // the same seed, same worker count, and matching initial state must
    // produce identical CFVs and identical post-solve regrets. If the pool
    // ever introduces ordering nondeterminism (e.g. losing the lock-step
    // semantics of the per-iter epoch broadcast → merge sequence), this
    // test fails.
    var da = std.heap.DebugAllocator(.{}){};
    defer _ = da.deinit();
    const temp_allocator = da.allocator();

    var arena_a = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_a.deinit();
    var arena_b = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_b.deinit();

    const board = [5]Card{
        card_mod.makeCard(5, 3),
        card_mod.makeCard(6, 1),
        card_mod.makeCard(0, 2),
        card_mod.makeCard(3, 3),
        card_mod.makeCard(2, 0),
    };

    const ht = HandTable.init();
    const aa_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 0), card_mod.makeCard(12, 1))).?;
    const kk_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(11, 3), card_mod.makeCard(11, 2))).?;

    const runOnce = struct {
        fn run(allocator: Allocator, arena_alloc: Allocator, b: [5]Card, aa: u16, kk: u16, out_p1: *[NUM_HANDS]f32, out_p2: *[NUM_HANDS]f32) ![]f32 {
            var state = gamestate_mod.GameState.init(.RIVER, true, 50, 100, 100);
            var arr = std.ArrayList(Edge).empty;
            defer arr.deinit(allocator);
            try node_mod.buildTree(&state, &arr, arena_alloc, allocator, NUM_HANDS, NUM_HANDS);
            const root = arr.items[0].child.?;

            var p1 = try range_mod.Range.initEmpty(allocator, 1);
            defer p1.deinit(allocator);
            p1.active_indices[0] = aa;
            p1.probs[0] = 1.0;
            var p2 = try range_mod.Range.initEmpty(allocator, 1);
            defer p2.deinit(allocator);
            p2.active_indices[0] = kk;
            p2.probs[0] = 1.0;

            var solver = try Solver.init(std.testing.io, b, &p1, &p2, 100, 100, 50);
            defer solver.deinit();
            solver.max_workers = 4;

            var prng = std.Random.DefaultPrng.init(0xCAFE);
            try solve(&solver, allocator, root, 50, prng.random(), out_p1, out_p2);

            // Snapshot the full regret state of the tree by walking it in
            // assignIds order. assignIds is deterministic, so two runs that
            // visit the same tree in the same order produce comparable
            // flattened vectors regardless of allocator addresses.
            _ = node_mod.assignIds(root);
            var snapshot = std.ArrayList(f32).empty;
            try collectRegrets(root, &snapshot, allocator);
            return try snapshot.toOwnedSlice(allocator);
        }

        fn collectRegrets(node: *Node, out: *std.ArrayList(f32), allocator: Allocator) !void {
            if (!node.is_leaf and !node.is_chance) {
                try out.appendSlice(allocator, node.regrets);
            }
            for (node.edges) |e| {
                if (e.child) |c| try collectRegrets(c, out, allocator);
            }
        }
    };

    var cfv_a_p1: [NUM_HANDS]f32 = undefined;
    var cfv_a_p2: [NUM_HANDS]f32 = undefined;
    const regrets_a = try runOnce.run(temp_allocator, arena_a.allocator(), board, aa_idx, kk_idx, &cfv_a_p1, &cfv_a_p2);
    defer temp_allocator.free(regrets_a);

    var cfv_b_p1: [NUM_HANDS]f32 = undefined;
    var cfv_b_p2: [NUM_HANDS]f32 = undefined;
    const regrets_b = try runOnce.run(temp_allocator, arena_b.allocator(), board, aa_idx, kk_idx, &cfv_b_p1, &cfv_b_p2);
    defer temp_allocator.free(regrets_b);

    // Last-iter CFV out-buffers come from worker 0 in both runs — must match.
    try std.testing.expectEqual(cfv_a_p1[aa_idx], cfv_b_p1[aa_idx]);
    try std.testing.expectEqual(cfv_a_p2[kk_idx], cfv_b_p2[kk_idx]);

    // Full regret state across the tree — the load-bearing equilibrium data —
    // must be bit-identical between two independent solves.
    try std.testing.expectEqual(regrets_a.len, regrets_b.len);
    for (regrets_a, regrets_b) |a, b| try std.testing.expectEqual(a, b);
}
