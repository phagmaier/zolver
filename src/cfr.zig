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

// Upper bound on recursion depth in `walk` / `brWalk`. With current betting
// rules the deepest reachable path is bounded by 3 streets × (≤2 bets +
// 1 response) + chance/showdown nodes, which empirically tops out around 15.
// 32 leaves plenty of headroom; the assert at function entry catches any
// future tree-shape change before it silently corrupts scratch slots.
const MAX_WALK_DEPTH: usize = 32;

// --- SIMD plumbing -----------------------------------------------------------
// Every per-hand inner loop in walk / brWalk / allInEquityLeaf / terminalFold
// runs over `0..NUM_HANDS = 1326`. We process them in fixed-width f32 vectors
// covering `[0, VEC_TAIL_START)`, then handle a scalar epilogue of
// `NUM_HANDS - VEC_TAIL_START` (≤ VEC_LANES − 1) entries. Layout of every
// hand-indexed array stays dense [NUM_HANDS]f32 — vectors are read/written via
// `slice[v..][0..VEC_LANES].*` pointer-array reinterpretation.
const VEC_LANES: comptime_int = std.simd.suggestVectorLength(f32) orelse 8;
const Vf = @Vector(VEC_LANES, f32);
const Vu32 = @Vector(VEC_LANES, u32);
const Vb = @Vector(VEC_LANES, bool);
const NUM_VEC_BLOCKS: usize = NUM_HANDS / VEC_LANES;
const VEC_TAIL_START: usize = NUM_VEC_BLOCKS * VEC_LANES;
const VEC_ZERO: Vf = @splat(0);

inline fn vload(buf: []const f32, off: usize) Vf {
    return buf[off..][0..VEC_LANES].*;
}

inline fn vstore(buf: []f32, off: usize, v: Vf) void {
    buf[off..][0..VEC_LANES].* = v;
}

// "Keep mask" derived once outside an inner loop and reused per vector block.
// Holds 1.0 in lanes where the hand survives the predicate, 0.0 elsewhere.
// Multiplying by this mask is identical to `if (keep) x else 0` but stays
// straight-line and vectorizes cleanly.
const KeepMask = [NUM_HANDS]f32;

// Build the keep-mask "hand `i` is not blocked by `card`" for the cached
// allInEquityLeaf path and the walk chance-sample path. `card == 0` means the
// slot isn't a real card (turn-leaf shape: only one card is dealt, the river
// slot is unused) and never blocks.
inline fn fillCardBlockMask(
    hands: []const range_mod.Hand,
    card: Card,
    out: *KeepMask,
) void {
    if (card == 0) {
        @memset(out, 1.0);
        return;
    }
    for (0..NUM_HANDS) |i| {
        out[i] = if (hands[i].card1 == card or hands[i].card2 == card) 0.0 else 1.0;
    }
}

// Same idea for a pair of cards: lane is 0 if the hand hits either card.
inline fn fillTwoCardBlockMask(
    hands: []const range_mod.Hand,
    card_a: Card,
    card_b: Card,
    out: *KeepMask,
) void {
    if (card_b == 0) {
        fillCardBlockMask(hands, card_a, out);
        return;
    }
    for (0..NUM_HANDS) |i| {
        const h = hands[i];
        const hit = h.card1 == card_a or h.card2 == card_a or h.card1 == card_b or h.card2 == card_b;
        out[i] = if (hit) 0.0 else 1.0;
    }
}

// Per-walk-frame scratch buffers, pre-allocated on the heap so the walk
// recursion no longer puts ~100 KB on the call stack per depth. One
// `WalkScratch` (= `MAX_WALK_DEPTH` frames) is owned by each `SolveContext`
// — workers don't share scratch with the dispatcher or with each other.
//
// Field naming reflects walk's usage; brWalk reuses the same memory for its
// equivalents (avg_strategy ↔ strategy, BR-branch full child_cfv ↔
// child_cfv_p1, opponent-branch single child_cfv ↔ br_child_cfv, dummy ↔
// br_dummy). walk and brWalk never execute concurrently on the same context.
const ScratchFrame = struct {
    strategy: [MAX_ACTIONS * NUM_HANDS]f32,
    child_cfv_p1: [MAX_ACTIONS * NUM_HANDS]f32,
    child_cfv_p2: [MAX_ACTIONS * NUM_HANDS]f32,
    new_p1_reach: [NUM_HANDS]f32,
    new_p2_reach: [NUM_HANDS]f32,
    masked_p1_reach: [NUM_HANDS]f32,
    masked_p2_reach: [NUM_HANDS]f32,
    // brWalk-only single-action scratch (opponent decision branch + dummy
    // sink for irrelevant-player CFV writes at terminal helpers).
    br_child_cfv: [NUM_HANDS]f32,
    br_dummy: [NUM_HANDS]f32,
};

pub const WalkScratch = struct {
    frames: []ScratchFrame,

    /// Use for SolveContexts that will only call terminal helpers (no
    /// recursive walk/brWalk descent). Costs nothing — empty slice.
    pub const empty: WalkScratch = .{ .frames = &.{} };

    pub fn init(allocator: Allocator) !WalkScratch {
        const frames = try allocator.alloc(ScratchFrame, MAX_WALK_DEPTH);
        return .{ .frames = frames };
    }

    pub fn deinit(self: *WalkScratch, allocator: Allocator) void {
        if (self.frames.len > 0) allocator.free(self.frames);
        self.frames = &.{};
    }
};

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

// DCFR (Brown & Sandholm 2019) discount factors, recomputed each iter from the
// 1-indexed iter count t. With (α=1.5, β=0, γ=2) the cumulative-regret update
// becomes
//     R_t  = pos_discount(t) * R_{t-1}^+ + neg_discount(t) * R_{t-1}^- + Δ_t
// and the strategy-sum update becomes
//     S_t  = strat_discount(t) * S_{t-1} + reach * strategy_t.
// β=0 gives a constant neg_discount of 0.5 — DCFR's "halve the bad" rule of
// thumb. The walk and mergeDeltas read these values per iter; the per-iter
// scalar cost is negligible.
//
// Note: postflop-solver uses γ=3 with a power-of-4 strategy-sum reset and a
// `(t-1)` α-shift that wipes iter-0 positive regrets at iter 1. The wipe
// breaks low-iter convergence on point-range subgames (see the trunc-vs-full
// turn re-solve verification test), so we keep the textbook DCFR(γ=2) here
// until a real exploitability-vs-iters workflow is in place to evaluate the
// tradeoff on representative spots.
pub const DcfrWeights = struct {
    regret_pos_discount: f32,
    regret_neg_discount: f32,
    strategy_sum_discount: f32,

    pub const ALPHA: f32 = 1.5;
    pub const BETA: f32 = 0.0;
    pub const GAMMA: f32 = 2.0;

    pub fn forIter(iter_idx_0: usize) DcfrWeights {
        const t: f32 = @floatFromInt(iter_idx_0 + 1);
        const t_alpha: f32 = std.math.pow(f32, t, ALPHA);
        const t_beta: f32 = std.math.pow(f32, t, BETA); // 1.0 when β=0
        const t_over_tp1: f32 = t / (t + 1.0);
        const gamma_factor: f32 = std.math.pow(f32, t_over_tp1, GAMMA);
        return .{
            .regret_pos_discount = t_alpha / (t_alpha + 1.0),
            .regret_neg_discount = t_beta / (t_beta + 1.0),
            .strategy_sum_discount = gamma_factor,
        };
    }
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

// Map a Card (with rank in bits 8..11 and one-hot suit in bits 12..15) to a
// dense 0..52 index. Used to bucket per-card reach contributions in the
// inclusion-exclusion terminal evaluators (see card.makeCard).
inline fn cardToDeckIdx(card: Card) usize {
    const rank: u32 = (card >> 8) & 0xF;
    const suit_bits: u32 = (card >> 12) & 0xF;
    const suit_idx: u32 = @ctz(suit_bits);
    return @intCast(rank * 4 + suit_idx);
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
        var empty_scratch = WalkScratch.empty;
        var ctx = SolveContext.initOnSolver(self, &empty_scratch);
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
        var empty_scratch = WalkScratch.empty;
        var ctx = SolveContext.initOnSolver(self, &empty_scratch);
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
        var empty_scratch = WalkScratch.empty;
        var ctx = SolveContext.initOnSolver(self, &empty_scratch);
        ctx.allInEquityLeaf(edge, p1_reach, p2_reach, out_cfv_p1, out_cfv_p2);
    }
};

// Per-walker context. Bundles a (shared) Solver with a (per-worker) BoardContext
// and a small fixed-size stack of board snapshots for chance save/restore. The
// walker (`walk`/`brWalk`) and the terminal/leaf helpers all operate through a
// `*SolveContext`, which is what makes parallel workers cleanly representable:
// each worker gets its own SolveContext over its own BoardContext, while the
// Solver itself (evaluator, hand_table, root reaches) is read-only
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
    /// Heap-resident per-frame scratch for walk / brWalk. Indexed by
    /// recursion depth. Caller owns the lifetime; SolveContext just borrows.
    scratch: *WalkScratch,

    /// Default ctor: a context that mutates the solver's own board_ctx in place.
    pub fn initOnSolver(solver: *Solver, scratch: *WalkScratch) SolveContext {
        return .{
            .solver = solver,
            .board_ctx = &solver.board_ctx,
            .snapshots = undefined,
            .chance_depth = 0,
            .allow_parallel = true,
            .scratch = scratch,
        };
    }

    /// Worker-style ctor: same Solver (immutable across workers) but a
    /// caller-owned BoardContext so multiple contexts can mutate board state
    /// without colliding. Caller is responsible for the BoardContext lifetime.
    pub fn initOnBoardContext(solver: *Solver, board_ctx: *BoardContext, scratch: *WalkScratch) SolveContext {
        return .{
            .solver = solver,
            .board_ctx = board_ctx,
            .snapshots = undefined,
            .chance_depth = 0,
            .allow_parallel = true,
            .scratch = scratch,
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

        // Inclusion-exclusion (postflop-solver-style). Per-hand "opp reach over
        // hands with no shared card" reduces from O(collisions) gather + branch
        // per hand to O(N + 52) total. Build:
        //   sum   = Σ opp_reach[j]
        //   minus[c] = Σ opp_reach[j] over hands containing card c
        // Then for player hand i with cards (c1, c2):
        //   valid_opp = sum - minus[c1] - minus[c2] + opp_reach[i]
        // The `+ opp_reach[i]` term restores the (c1, c2) hand itself which was
        // subtracted twice (once for c1, once for c2) and added once in sum —
        // net -1 — and correctly zeroes its contribution, since opp can't
        // physically hold the same cards as player.
        //
        // f64 accumulators preserve precision across 1326 lane sums.
        const hands = solver.hand_table.all_hands;
        var p1_sum: f64 = 0;
        var p2_sum: f64 = 0;
        var p1_minus: [52]f64 = @splat(0);
        var p2_minus: [52]f64 = @splat(0);

        for (0..NUM_HANDS) |i| {
            const r1: f64 = @as(f64, p1_reach[i]);
            const r2: f64 = @as(f64, p2_reach[i]);
            if (r1 == 0 and r2 == 0) continue;
            const h = hands[i];
            const c1 = cardToDeckIdx(h.card1);
            const c2 = cardToDeckIdx(h.card2);
            p1_sum += r1;
            p2_sum += r2;
            p1_minus[c1] += r1;
            p1_minus[c2] += r1;
            p2_minus[c1] += r2;
            p2_minus[c2] += r2;
        }

        for (0..NUM_HANDS) |i| {
            if (self.board_ctx.blocked[i]) {
                out_cfv_p1[i] = 0;
                out_cfv_p2[i] = 0;
                continue;
            }
            const h = hands[i];
            const c1 = cardToDeckIdx(h.card1);
            const c2 = cardToDeckIdx(h.card2);
            const opp_p2_mass = p2_sum - p2_minus[c1] - p2_minus[c2] + @as(f64, p2_reach[i]);
            const opp_p1_mass = p1_sum - p1_minus[c1] - p1_minus[c2] + @as(f64, p1_reach[i]);
            out_cfv_p1[i] = @floatCast(@as(f64, p1_payoff) * opp_p2_mass);
            out_cfv_p2[i] = @floatCast(@as(f64, p2_payoff) * opp_p1_mass);
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
        const hands = self.solver.hand_table.all_hands;
        const sorted = &board_ctx.sorted_indices;

        // Inclusion-exclusion in strength order (postflop-solver-style). The
        // per-hand collision-correction inner loop (~100 gathers per of 1326
        // player hands) is replaced by two streaming O(N + 52) passes:
        //
        //   Pass 1 (ascending): maintain (sum, minus[card]) over opp hands
        //     with strength strictly less than the current bucket. For each
        //     player hand i with cards (c1, c2), valid-opp win mass =
        //     sum - minus[c1] - minus[c2]. Write payoff * win_mass to out.
        //   Pass 2 (descending): same shape, opp strictly greater. Subtract
        //     payoff * loss_mass from out.
        //
        // Ties (opp at same strength) contribute zero, and are naturally
        // excluded by the strict-strength condition — the opp hand at the
        // *same* index as player has the same cards, hence the same strength,
        // and is never in the strict-less or strict-greater accumulator when
        // we read it, so no `cfreach_same` correction is needed here.
        // f64 accumulators preserve precision across 1326 contributions.

        // ----- Pass 1: forward, write win mass -----
        {
            var cfreach_sum: f64 = 0;
            var cfreach_minus: [52]f64 = @splat(0);
            var i: usize = 0;
            while (i < NUM_HANDS) {
                const bucket_top = sorted[i];
                const bucket_end: usize = @as(usize, board_ctx.last_rank[bucket_top]) + 1;
                // Write win_mass for each player hand in this bucket using the
                // current (strict-less) accumulator.
                for (i..bucket_end) |k| {
                    const pi = sorted[k];
                    if (board_ctx.blocked[pi]) {
                        out[pi] = 0;
                        continue;
                    }
                    const h = hands[pi];
                    const c1 = cardToDeckIdx(h.card1);
                    const c2 = cardToDeckIdx(h.card2);
                    const win_mass = cfreach_sum - cfreach_minus[c1] - cfreach_minus[c2];
                    out[pi] = @floatCast(@as(f64, payoff) * win_mass);
                }
                // Fold this bucket's opp reach into the accumulator for the
                // next (strictly-greater) buckets.
                for (i..bucket_end) |k| {
                    const oj = sorted[k];
                    const rj: f64 = @as(f64, reach[oj]);
                    if (rj == 0) continue;
                    const hj = hands[oj];
                    cfreach_sum += rj;
                    cfreach_minus[cardToDeckIdx(hj.card1)] += rj;
                    cfreach_minus[cardToDeckIdx(hj.card2)] += rj;
                }
                i = bucket_end;
            }
        }

        // ----- Pass 2: reverse, subtract loss mass -----
        {
            var cfreach_sum: f64 = 0;
            var cfreach_minus: [52]f64 = @splat(0);
            var i: usize = NUM_HANDS;
            while (i > 0) {
                const bucket_top = sorted[i - 1];
                const bucket_first: usize = @intCast(board_ctx.first_rank[bucket_top]);
                // Subtract loss_mass for each player hand in this bucket using
                // the current (strict-greater) accumulator.
                for (bucket_first..i) |k| {
                    const pi = sorted[k];
                    if (board_ctx.blocked[pi]) continue; // out[pi] already 0 from pass 1
                    const h = hands[pi];
                    const c1 = cardToDeckIdx(h.card1);
                    const c2 = cardToDeckIdx(h.card2);
                    const loss_mass = cfreach_sum - cfreach_minus[c1] - cfreach_minus[c2];
                    out[pi] = @floatCast(@as(f64, out[pi]) - @as(f64, payoff) * loss_mass);
                }
                // Fold this bucket's opp reach into the accumulator for the
                // next (strictly-lesser) buckets.
                for (bucket_first..i) |k| {
                    const oj = sorted[k];
                    const rj: f64 = @as(f64, reach[oj]);
                    if (rj == 0) continue;
                    const hj = hands[oj];
                    cfreach_sum += rj;
                    cfreach_minus[cardToDeckIdx(hj.card1)] += rj;
                    cfreach_minus[cardToDeckIdx(hj.card2)] += rj;
                }
                i = bucket_first;
            }
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
            var keep_mask: KeepMask = undefined;

            for (cache) |*cached| {
                const new1: Card = if (num_board_cards == 4) cached.board[4] else cached.board[3];
                const new2: Card = if (num_board_cards == 4) 0 else cached.board[4];

                fillTwoCardBlockMask(&hands, new1, new2, &keep_mask);

                {
                    var v: usize = 0;
                    while (v < VEC_TAIL_START) : (v += VEC_LANES) {
                        const km = vload(&keep_mask, v);
                        vstore(&masked_p1, v, vload(p1_reach, v) * km);
                        vstore(&masked_p2, v, vload(p2_reach, v) * km);
                    }
                    var i: usize = VEC_TAIL_START;
                    while (i < NUM_HANDS) : (i += 1) {
                        masked_p1[i] = p1_reach[i] * keep_mask[i];
                        masked_p2[i] = p2_reach[i] * keep_mask[i];
                    }
                }

                self.computeShowdownCFVFor(cached, &masked_p2, &runout_cfv_p1, half_pot);
                self.computeShowdownCFVFor(cached, &masked_p1, &runout_cfv_p2, half_pot);

                {
                    var v: usize = 0;
                    while (v < VEC_TAIL_START) : (v += VEC_LANES) {
                        const km = vload(&keep_mask, v);
                        vstore(out_cfv_p1, v, vload(out_cfv_p1, v) + vload(&runout_cfv_p1, v) * km);
                        vstore(out_cfv_p2, v, vload(out_cfv_p2, v) + vload(&runout_cfv_p2, v) * km);
                    }
                    var i: usize = VEC_TAIL_START;
                    while (i < NUM_HANDS) : (i += 1) {
                        out_cfv_p1[i] += runout_cfv_p1[i] * keep_mask[i];
                        out_cfv_p2[i] += runout_cfv_p2[i] * keep_mask[i];
                    }
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

// Sum every worker's deltas into the shared tree and apply the DCFR discount.
// Each worker's slot is zeroed in the same pass so the next iteration's walks
// can `+=` from a clean baseline without a separate reset step. Uses the flat
// per-worker NodeDelta list — workers all register in the same tree-walk
// order, so the flat-list indices align across workers.
//
// DCFR update applied to the shared storage:
//   R_t = pos_discount * R_{t-1}^+ + neg_discount * R_{t-1}^- + Σ Δ_w
//   S_t = strat_discount * S_{t-1} + Σ s_delta_w
// Negative regrets are kept (no CFR+ clamp); regret matching at the next
// walk reads max(0, R) when computing the strategy.
fn mergeDeltas(workers: []const *WorkerDeltas, weights: DcfrWeights) void {
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
            const r_old = target.regrets[i];
            const discount: f32 = if (r_old > 0) weights.regret_pos_discount else weights.regret_neg_discount;
            target.regrets[i] = r_old * discount + r_sum;
            target.strategy_sum[i] = target.strategy_sum[i] * weights.strategy_sum_discount + s_sum;
        }
    }
}

// DCFR(α=1.5, β=0, γ=2) solve loop. Per iter t (1-indexed):
//   * Positive cumulative regret is discounted by t^α/(t^α+1) — slow decay.
//   * Negative cumulative regret is discounted by t^β/(t^β+1) = 1/2 — fast
//     decay (β=0). DCFR's "halve the bad" rule converges faster than CFR+ in
//     practice while keeping signed-regret accounting simple.
//   * strategy_sum is discounted by (t/(t+1))^γ, which is equivalent to
//     weighting iter t's contribution by t^γ in the cumulative average.
// The dense reach vectors (solver.p1_reach / p2_reach) seed the traversal;
// out buffers receive the per-hand counterfactual values from the *last*
// iteration's walk.
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
        // Serial fallback. No deltas, no thread spawn. Still needs a scratch
        // since `walk` reads its frame buffers unconditionally.
        var serial_scratch = try WalkScratch.init(allocator);
        defer serial_scratch.deinit(allocator);
        var ctx = SolveContext.initOnSolver(self, &serial_scratch);
        var iter: usize = 0;
        while (iter < iterations) : (iter += 1) {
            const weights = DcfrWeights.forIter(iter);
            walk(&ctx, root, &self.p1_reach, &self.p2_reach, out_cfv_p1, out_cfv_p2, random, weights, null, 0);
        }
        return;
    }

    // Parallel path. Per-worker state lives on the dispatcher's stack /
    // dispatcher-managed heap so worker threads only need pointers.
    var worker_boards: [MAX_PARALLEL_WORKERS]BoardContext = undefined;
    var worker_ctxs: [MAX_PARALLEL_WORKERS]SolveContext = undefined;
    var worker_deltas: [MAX_PARALLEL_WORKERS]WorkerDeltas = undefined;
    var worker_scratches: [MAX_PARALLEL_WORKERS]WalkScratch = undefined;
    var worker_prngs: [MAX_PARALLEL_WORKERS]std.Random.DefaultPrng = undefined;
    var worker_out_p1: [MAX_PARALLEL_WORKERS][NUM_HANDS]f32 = undefined;
    var worker_out_p2: [MAX_PARALLEL_WORKERS][NUM_HANDS]f32 = undefined;
    var worker_ptrs: [MAX_PARALLEL_WORKERS]*WorkerDeltas = undefined;

    // Seed each worker's PRNG deterministically from the caller's `random` so
    // results are reproducible given a fixed input seed.
    const base_seed: u64 = random.int(u64);

    // Track scratch / delta init separately so an error mid-loop frees only
    // what was actually allocated (the two allocations within one iteration
    // can each fail independently).
    var scratches_init: usize = 0;
    var deltas_init: usize = 0;
    errdefer {
        for (0..deltas_init) |i| worker_deltas[i].deinit();
        for (0..scratches_init) |i| worker_scratches[i].deinit(allocator);
    }
    var t: usize = 0;
    while (t < n_workers) : (t += 1) {
        worker_boards[t] = self.board_ctx;
        worker_scratches[t] = try WalkScratch.init(allocator);
        scratches_init = t + 1;
        worker_ctxs[t] = SolveContext.initOnBoardContext(self, &worker_boards[t], &worker_scratches[t]);
        worker_ctxs[t].allow_parallel = false;
        worker_deltas[t] = try WorkerDeltas.init(allocator, root);
        deltas_init = t + 1;
        worker_prngs[t] = std.Random.DefaultPrng.init(base_seed +% t);
        worker_ptrs[t] = &worker_deltas[t];
    }
    defer {
        for (0..n_workers) |i| worker_deltas[i].deinit();
        for (0..n_workers) |i| worker_scratches[i].deinit(allocator);
    }

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
            .job = .{
                .ctx = &worker_ctxs[s],
                .root = root,
                .p1_reach = &self.p1_reach,
                .p2_reach = &self.p2_reach,
                .out_cfv_p1 = &worker_out_p1[s],
                .out_cfv_p2 = &worker_out_p2[s],
                .random = worker_prngs[s].random(),
                .weights = DcfrWeights.forIter(0),
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
            pool.shutdown.store(true, .release);
            threads[0].join();
        }
        // Reuse worker_scratches[0] for the serial fallback — already
        // allocated, will be freed by the outer defer.
        var ctx2 = SolveContext.initOnSolver(self, &worker_scratches[0]);
        var iter2: usize = 0;
        while (iter2 < iterations) : (iter2 += 1) {
            const weights = DcfrWeights.forIter(iter2);
            walk(&ctx2, root, &self.p1_reach, &self.p2_reach, out_cfv_p1, out_cfv_p2, random, weights, null, 0);
        }
        return;
    }

    // From here on, `spawned` workers are spinning on `epoch` waiting for the
    // first dispatch. Shutdown on any exit path joins them cleanly — workers
    // see `shutdown=true` on their next spin-check (within ~1µs).
    defer {
        pool.shutdown.store(true, .release);
        for (0..spawned) |i| threads[i].join();
    }

    const actual_workers = spawned;
    const record = self.record_timings;

    // `iterations` is the number of strategy updates — same semantics as the
    // serial loop. Each update dispatches N parallel walks that contribute
    // lower-variance samples to the per-update delta, then merges.
    var iter: usize = 0;
    while (iter < iterations) : (iter += 1) {
        const weights = DcfrWeights.forIter(iter);

        const t_iter_start: ?std.Io.Clock.Timestamp = if (record)
            std.Io.Clock.Timestamp.now(io, .awake)
        else
            null;

        // Workers are spinning on `epoch`: safe to write per-iter job fields
        // before the epoch bump publishes them via release/acquire.
        for (0..actual_workers) |w| workers[w].job.weights = weights;

        pool.workers_done.store(0, .release);
        _ = pool.epoch.fetchAdd(1, .release);

        const t_after_spawn: ?std.Io.Clock.Timestamp = if (record)
            std.Io.Clock.Timestamp.now(io, .awake)
        else
            null;

        // Spin-wait for all workers to finish. Pairs with worker's
        // `.release` fetchAdd so we observe their delta-buffer writes.
        {
            var spin: usize = 0;
            while (pool.workers_done.load(.acquire) < actual_workers) {
                if (spin < POOL_SPIN_BUDGET) {
                    std.atomic.spinLoopHint();
                    spin += 1;
                } else {
                    std.Thread.yield() catch {};
                }
            }
        }

        const t_after_join: ?std.Io.Clock.Timestamp = if (record)
            std.Io.Clock.Timestamp.now(io, .awake)
        else
            null;

        mergeDeltas(worker_ptrs[0..actual_workers], weights);

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
    weights: DcfrWeights,
    deltas: *WorkerDeltas,

    fn run(self: *WalkJob) void {
        walk(self.ctx, self.root, self.p1_reach, self.p2_reach, self.out_cfv_p1, self.out_cfv_p2, self.random, self.weights, self.deltas, 0);
    }
};

// Coordinates the persistent worker pool used by `solve`. One instance lives
// on the dispatcher's stack for the duration of a single `solve` call; the
// pool is torn down before `solve` returns.
//
// All synchronization is via atomics + spin-with-yield. The previous design
// used `std.Io.Mutex` + two `std.Io.Condition`s; with the post-IE walk now
// down to ~50–500us per worker, the per-iter `Mutex.lock` + `Condition.wait`
// round-trip (~500us at workers=2 on the river bench) dominated the budget.
// Atomic + spin is brutal but right for this workload: workers are sized to
// fit available cores (capped at `MAX_PARALLEL_WORKERS`), so a spinning
// worker isn't denying anyone else CPU; and a brief spin with a `yield`
// fallback after ~1024 iterations bounds the wasted cycles when a walk is
// long enough that the OS scheduler would benefit from being involved.
//
// Memory ordering pairs:
//   - dispatcher writes `job.weights`, then `epoch.fetchAdd(.release)` →
//     worker `epoch.load(.acquire)` sees both.
//   - worker writes `worker_deltas[t]` (via WalkJob.run), then
//     `workers_done.fetchAdd(.release)` → dispatcher
//     `workers_done.load(.acquire)` then reads the deltas in `mergeDeltas`.
//   - `shutdown.store(.release)` / `shutdown.load(.acquire)` pair.
const ParallelPool = struct {
    epoch: std.atomic.Value(u64) = .init(0),
    workers_done: std.atomic.Value(usize) = .init(0),
    n_workers: usize = 0,
    shutdown: std.atomic.Value(bool) = .init(false),
};

// Spin parameter shared by worker (epoch wait) and dispatcher (done wait).
// 1024 spin iterations on a modern x86 core is ~1–3µs — short enough to
// disappear under the per-iter join budget for short walks, long enough that
// the OS scheduler doesn't get involved when the wait would resolve quickly.
const POOL_SPIN_BUDGET: usize = 1024;

// One persistent worker. `job` is filled by the dispatcher before the pool
// is started and only `job.weights` is updated between epochs.
const PoolWorker = struct {
    pool: *ParallelPool,
    job: WalkJob,

    fn run(self: *PoolWorker) void {
        var last_epoch: u64 = 0;
        while (true) {
            // Wait for a new epoch or shutdown. Spin briefly, then yield.
            const my_epoch = blk: {
                var spin: usize = 0;
                while (true) {
                    if (self.pool.shutdown.load(.acquire)) return;
                    const cur = self.pool.epoch.load(.acquire);
                    if (cur != last_epoch) break :blk cur;
                    if (spin < POOL_SPIN_BUDGET) {
                        std.atomic.spinLoopHint();
                        spin += 1;
                    } else {
                        std.Thread.yield() catch {};
                    }
                }
            };

            WalkJob.run(&self.job);

            last_epoch = my_epoch;
            // `.release` publishes the worker's writes to its delta buffers
            // and output slot to whichever dispatcher load eventually sees
            // the incremented counter.
            _ = self.pool.workers_done.fetchAdd(1, .release);
        }
    }
};

// Single recursive pass. Computes per-hand CFV for both players, then updates
// the acting player's regrets and strategy_sum using DCFR's update rule
// (regret and strategy-sum storage are both discounted by per-iter factors
// supplied via `weights`). Both players' regret tables get updated across the
// full walk (one iteration = one tree traversal), since each decision node
// belongs to exactly one of them and only that player's tables get touched
// there.
fn walk(
    ctx: *SolveContext,
    node: *Node,
    p1_reach: []const f32,
    p2_reach: []const f32,
    out_cfv_p1: []f32,
    out_cfv_p2: []f32,
    random: std.Random,
    weights: DcfrWeights,
    deltas: ?*WorkerDeltas,
    depth: usize,
) void {
    std.debug.assert(depth < MAX_WALK_DEPTH);
    const hands = ctx.solver.hand_table.all_hands;
    const frame = &ctx.scratch.frames[depth];

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

        // Precompute per-hand keep/scale masks BEFORE `reinitForBoard` mutates
        // `board_ctx.blocked` — the importance scale below depends on whether
        // each hand was blocked by the *saved* board, not the new one.
        var keep_mask: KeepMask = undefined;
        var scale_mask: KeepMask = undefined;
        const saved_blocked = ctx.board_ctx.blocked;
        for (0..NUM_HANDS) |i| {
            const h = hands[i];
            const hits_c: bool = (h.card1 == c or h.card2 == c);
            keep_mask[i] = if (hits_c) 0.0 else 1.0;
            scale_mask[i] = if (hits_c or saved_blocked[i]) 0.0 else 1.0;
        }

        // Update strengths for this sampled runout.
        ctx.reinitForBoard(new_board);

        // Card removal: hands containing the sampled card become illegal on the
        // new board. Zero their reach before recursing so downstream regret /
        // strategy_sum updates don't accumulate mass for hands that aren't in
        // the player's effective range on this runout.
        {
            var v: usize = 0;
            while (v < VEC_TAIL_START) : (v += VEC_LANES) {
                const km = vload(&keep_mask, v);
                vstore(&frame.masked_p1_reach, v, vload(p1_reach, v) * km);
                vstore(&frame.masked_p2_reach, v, vload(p2_reach, v) * km);
            }
            var i: usize = VEC_TAIL_START;
            while (i < NUM_HANDS) : (i += 1) {
                frame.masked_p1_reach[i] = p1_reach[i] * keep_mask[i];
                frame.masked_p2_reach[i] = p2_reach[i] * keep_mask[i];
            }
        }

        // Recurse into the single chance child (Action.CHANCE).
        // In sampled CFR, we don't weight by 1/N because the sampling distribution
        // (uniform over legal cards) naturally handles the probability over iterations.
        // A null child means the chance edge leads directly to a showdown — happens
        // when an all-in is called pre-river, so the runout chain ends in showdown
        // rather than another decision node.
        const chance_edge = &node.edges[0];
        if (chance_edge.child) |child| {
            walk(ctx, child, &frame.masked_p1_reach, &frame.masked_p2_reach, out_cfv_p1, out_cfv_p2, random, weights, deltas, depth + 1);
        } else {
            ctx.terminalShowdown(chance_edge, &frame.masked_p1_reach, &frame.masked_p2_reach, out_cfv_p1, out_cfv_p2);
        }

        // The sample is drawn uniformly from public cards. Per-hand CFVs need
        // to be conditioned on that hand's blockers — `scale_mask` is 0 for
        // hands blocked by the saved board or by the new card, 1 otherwise,
        // and the constant `S = N/(N-2)` applies to every other lane.
        const N_f: f32 = @floatFromInt(publicChanceCardCount(saved_board));
        const S: f32 = if (N_f > 2.0) (N_f / (N_f - 2.0)) else 0.0;
        const S_vec: Vf = @splat(S);
        {
            var v: usize = 0;
            while (v < VEC_TAIL_START) : (v += VEC_LANES) {
                const m = vload(&scale_mask, v);
                const f = S_vec * m;
                vstore(out_cfv_p1, v, vload(out_cfv_p1, v) * f);
                vstore(out_cfv_p2, v, vload(out_cfv_p2, v) * f);
            }
            var i: usize = VEC_TAIL_START;
            while (i < NUM_HANDS) : (i += 1) {
                const f = S * scale_mask[i];
                out_cfv_p1[i] *= f;
                out_cfv_p2[i] *= f;
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
    // Vectorize across hands; action loop stays inner. CFR+ keeps cumulative
    // regret non-negative, so the @max() against zero in the sum is a no-op in
    // steady state but cheap insurance during the first iters when negative
    // values can leak through merge ordering.
    {
        const uniform: f32 = 1.0 / @as(f32, @floatFromInt(n_actions));
        const uniform_vec: Vf = @splat(uniform);
        const safe_one: Vf = @splat(1.0);
        var v: usize = 0;
        while (v < VEC_TAIL_START) : (v += VEC_LANES) {
            var pos_sum: Vf = VEC_ZERO;
            var a: usize = 0;
            while (a < n_actions) : (a += 1) {
                const r = vload(node.regrets, a * NUM_HANDS + v);
                pos_sum += @max(r, VEC_ZERO);
            }
            const has_pos = pos_sum > VEC_ZERO;
            const safe_sum = @select(f32, has_pos, pos_sum, safe_one);
            a = 0;
            while (a < n_actions) : (a += 1) {
                const r = vload(node.regrets, a * NUM_HANDS + v);
                const ratio = @max(r, VEC_ZERO) / safe_sum;
                vstore(&frame.strategy, a * NUM_HANDS + v, @select(f32, has_pos, ratio, uniform_vec));
            }
        }
        var i: usize = VEC_TAIL_START;
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
                    frame.strategy[a * NUM_HANDS + i] = if (r > 0) r / pos_sum else 0;
                }
            } else {
                a = 0;
                while (a < n_actions) : (a += 1) {
                    frame.strategy[a * NUM_HANDS + i] = uniform;
                }
            }
        }
    }

    // --- 2. Recurse into each child, filling per-action CFV slots. ---
    for (node.edges, 0..) |*edge, a| {
        const off = a * NUM_HANDS;
        // Only the actor's reach gets scaled by their strategy on this action.
        if (actor_isp1) {
            var v: usize = 0;
            while (v < VEC_TAIL_START) : (v += VEC_LANES) {
                vstore(&frame.new_p1_reach, v, vload(p1_reach, v) * vload(&frame.strategy, off + v));
                vstore(&frame.new_p2_reach, v, vload(p2_reach, v));
            }
            var i: usize = VEC_TAIL_START;
            while (i < NUM_HANDS) : (i += 1) {
                frame.new_p1_reach[i] = p1_reach[i] * frame.strategy[off + i];
                frame.new_p2_reach[i] = p2_reach[i];
            }
        } else {
            var v: usize = 0;
            while (v < VEC_TAIL_START) : (v += VEC_LANES) {
                vstore(&frame.new_p1_reach, v, vload(p1_reach, v));
                vstore(&frame.new_p2_reach, v, vload(p2_reach, v) * vload(&frame.strategy, off + v));
            }
            var i: usize = VEC_TAIL_START;
            while (i < NUM_HANDS) : (i += 1) {
                frame.new_p1_reach[i] = p1_reach[i];
                frame.new_p2_reach[i] = p2_reach[i] * frame.strategy[off + i];
            }
        }

        const cfv_p1_slot = frame.child_cfv_p1[off .. off + NUM_HANDS];
        const cfv_p2_slot = frame.child_cfv_p2[off .. off + NUM_HANDS];

        if (edge.child) |child| {
            walk(ctx, child, &frame.new_p1_reach, &frame.new_p2_reach, cfv_p1_slot, cfv_p2_slot, random, weights, deltas, depth + 1);
        } else {
            switch (edge.action) {
                .FOLD => ctx.terminalFold(edge, actor_isp1, &frame.new_p1_reach, &frame.new_p2_reach, cfv_p1_slot, cfv_p2_slot),
                .CHECK, .CALL => ctx.terminalShowdown(edge, &frame.new_p1_reach, &frame.new_p2_reach, cfv_p1_slot, cfv_p2_slot),
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
            var v: usize = 0;
            while (v < VEC_TAIL_START) : (v += VEC_LANES) {
                const strat = vload(&frame.strategy, off + v);
                vstore(out_cfv_p1, v, vload(out_cfv_p1, v) + strat * vload(&frame.child_cfv_p1, off + v));
                vstore(out_cfv_p2, v, vload(out_cfv_p2, v) + vload(&frame.child_cfv_p2, off + v));
            }
            var i: usize = VEC_TAIL_START;
            while (i < NUM_HANDS) : (i += 1) {
                out_cfv_p1[i] += frame.strategy[off + i] * frame.child_cfv_p1[off + i];
                out_cfv_p2[i] += frame.child_cfv_p2[off + i];
            }
        }
    } else {
        var a: usize = 0;
        while (a < n_actions) : (a += 1) {
            const off = a * NUM_HANDS;
            var v: usize = 0;
            while (v < VEC_TAIL_START) : (v += VEC_LANES) {
                const strat = vload(&frame.strategy, off + v);
                vstore(out_cfv_p1, v, vload(out_cfv_p1, v) + vload(&frame.child_cfv_p1, off + v));
                vstore(out_cfv_p2, v, vload(out_cfv_p2, v) + strat * vload(&frame.child_cfv_p2, off + v));
            }
            var i: usize = VEC_TAIL_START;
            while (i < NUM_HANDS) : (i += 1) {
                out_cfv_p1[i] += frame.child_cfv_p1[off + i];
                out_cfv_p2[i] += frame.strategy[off + i] * frame.child_cfv_p2[off + i];
            }
        }
    }

    // --- 4. Regret + strategy_sum updates for the actor at this node. ---
    // DCFR(α=1.5, β=0, γ=2) update rule:
    //   R_t   = pos_discount * max(0, R_{t-1}) + neg_discount * min(0, R_{t-1}) + Δ
    //   S_t   = strat_discount * S_{t-1} + reach * strategy
    // Negative regrets are allowed to accumulate (no CFR+ clamp); regret
    // matching itself uses max(0, R) when computing the strategy, so storage
    // can stay signed.
    //
    // Parallel path: when `deltas` is non-null, workers accumulate raw deltas
    // (`+= Δ` for regret, `+= reach*strategy` for strategy_sum) and the merge
    // step in `mergeDeltas` applies the per-iter discount to the existing
    // shared storage. No worker-side discount is needed.
    const actor_reach: []const f32 = if (actor_isp1) p1_reach else p2_reach;
    const actor_cfv_buf: []const f32 = if (actor_isp1) &frame.child_cfv_p1 else &frame.child_cfv_p2;
    const actor_out_cfv: []const f32 = if (actor_isp1) out_cfv_p1 else out_cfv_p2;
    if (deltas) |d| {
        const r_delta = d.regret_delta.get(node).?;
        const s_delta = d.strategy_sum_delta.get(node).?;
        var a: usize = 0;
        while (a < n_actions) : (a += 1) {
            const off = a * NUM_HANDS;
            var v: usize = 0;
            while (v < VEC_TAIL_START) : (v += VEC_LANES) {
                const cfv_a = vload(actor_cfv_buf, off + v);
                const cfv_n = vload(actor_out_cfv, v);
                vstore(r_delta, off + v, vload(r_delta, off + v) + (cfv_a - cfv_n));
                const reach = vload(actor_reach, v);
                const strat = vload(&frame.strategy, off + v);
                vstore(s_delta, off + v, vload(s_delta, off + v) + reach * strat);
            }
            var i: usize = VEC_TAIL_START;
            while (i < NUM_HANDS) : (i += 1) {
                r_delta[off + i] += actor_cfv_buf[off + i] - actor_out_cfv[i];
                s_delta[off + i] += actor_reach[i] * frame.strategy[off + i];
            }
        }
    } else {
        // Serial path: apply the DCFR discount to existing storage in-place
        // before folding the new instantaneous regret / strategy contribution.
        const pos_d_vec: Vf = @splat(weights.regret_pos_discount);
        const neg_d_vec: Vf = @splat(weights.regret_neg_discount);
        const strat_d_vec: Vf = @splat(weights.strategy_sum_discount);
        var a: usize = 0;
        while (a < n_actions) : (a += 1) {
            const off = a * NUM_HANDS;
            var v: usize = 0;
            while (v < VEC_TAIL_START) : (v += VEC_LANES) {
                const r_old = vload(node.regrets, off + v);
                const is_pos = r_old > VEC_ZERO;
                const discount = @select(f32, is_pos, pos_d_vec, neg_d_vec);
                const r_discounted = r_old * discount;
                const delta = vload(actor_cfv_buf, off + v) - vload(actor_out_cfv, v);
                vstore(node.regrets, off + v, r_discounted + delta);

                const s_old = vload(node.strategy_sum, off + v);
                const reach = vload(actor_reach, v);
                const strat = vload(&frame.strategy, off + v);
                vstore(node.strategy_sum, off + v, s_old * strat_d_vec + reach * strat);
            }
            var i: usize = VEC_TAIL_START;
            while (i < NUM_HANDS) : (i += 1) {
                const r_old = node.regrets[off + i];
                const discount: f32 = if (r_old > 0) weights.regret_pos_discount else weights.regret_neg_discount;
                node.regrets[off + i] = r_old * discount + (actor_cfv_buf[off + i] - actor_out_cfv[i]);
                node.strategy_sum[off + i] = node.strategy_sum[off + i] * weights.strategy_sum_discount + actor_reach[i] * frame.strategy[off + i];
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
    allocator: Allocator,
    node: *Node,
    p1_reach: []const f32,
    p2_reach: []const f32,
    br_isp1: bool,
    out_cfv: []f32,
    depth: usize,
) void {
    std.debug.assert(depth < MAX_WALK_DEPTH);
    const hands = ctx.solver.hand_table.all_hands;
    const frame = &ctx.scratch.frames[depth];

    if (node.is_chance) {
        if (node.is_leaf) {
            if (br_isp1) {
                ctx.allInEquityLeaf(&node.edges[0], p1_reach, p2_reach, out_cfv, &frame.br_dummy);
            } else {
                ctx.allInEquityLeaf(&node.edges[0], p1_reach, p2_reach, &frame.br_dummy, out_cfv);
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
            brChanceWorker(ctx, allocator, node, saved_board, card_to_fill_idx, legal_cards[0..n_legal], p1_reach, p2_reach, br_isp1, out_cfv, depth);
        } else {
            // Parallel path: per-worker BoardContext + SolveContext + scratch + output slot.
            // brWalk is exploitability-only and rare; per-call heap allocation
            // for the worker scratches is the simplest correct option (each
            // worker recurses from depth 0 into its own scratch).
            var worker_boards: [MAX_PARALLEL_WORKERS]BoardContext = undefined;
            var worker_ctxs: [MAX_PARALLEL_WORKERS]SolveContext = undefined;
            var worker_scratches: [MAX_PARALLEL_WORKERS]WalkScratch = undefined;
            var worker_outs: [MAX_PARALLEL_WORKERS][NUM_HANDS]f32 = undefined;
            var threads: [MAX_PARALLEL_WORKERS]std.Thread = undefined;
            var jobs: [MAX_PARALLEL_WORKERS]BrChanceJob = undefined;

            // Allocate all worker scratches up front. On allocation failure
            // fall back to serial — it's an exploitability path, correctness
            // matters more than parallel speedup.
            var allocated: usize = 0;
            errdefer for (0..allocated) |i| worker_scratches[i].deinit(allocator);
            while (allocated < n_workers) {
                worker_scratches[allocated] = WalkScratch.init(allocator) catch break;
                allocated += 1;
            }
            if (allocated < n_workers) {
                for (0..allocated) |i| worker_scratches[i].deinit(allocator);
                @memset(out_cfv, 0);
                brChanceWorker(ctx, allocator, node, saved_board, card_to_fill_idx, legal_cards[0..n_legal], p1_reach, p2_reach, br_isp1, out_cfv, depth);
            } else {
                defer for (0..n_workers) |i| worker_scratches[i].deinit(allocator);

                var t: usize = 0;
                while (t < n_workers) : (t += 1) {
                    const start = (t * n_legal) / n_workers;
                    const end = ((t + 1) * n_legal) / n_workers;

                    worker_boards[t] = saved_board_ctx;
                    worker_ctxs[t] = SolveContext.initOnBoardContext(ctx.solver, &worker_boards[t], &worker_scratches[t]);
                    worker_ctxs[t].allow_parallel = false;

                    jobs[t] = .{
                        .ctx = &worker_ctxs[t],
                        .allocator = allocator,
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
                        BrChanceJob.run(&jobs[t]);
                        var j: usize = 0;
                        while (j < t) : (j += 1) threads[j].join();
                        break;
                    };
                }
                const joined_target = if (t == n_workers) n_workers else t;
                var j: usize = 0;
                while (j < joined_target) : (j += 1) threads[j].join();

                for (0..NUM_HANDS) |i| {
                    var sum: f32 = 0;
                    var k: usize = 0;
                    while (k < n_workers) : (k += 1) sum += worker_outs[k][i];
                    out_cfv[i] = sum;
                }
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
        // since BR plays a pure (per-hand) strategy. Reuses the walk frame's
        // child_cfv_p1 (same shape: MAX_ACTIONS × NUM_HANDS) and br_dummy.
        for (node.edges, 0..) |*edge, a| {
            const off = a * NUM_HANDS;
            const slot = frame.child_cfv_p1[off .. off + NUM_HANDS];
            if (edge.child) |child| {
                brWalk(ctx, allocator, child, p1_reach, p2_reach, br_isp1, slot, depth + 1);
            } else if (br_isp1) {
                switch (edge.action) {
                    .FOLD => ctx.terminalFold(edge, actor_isp1, p1_reach, p2_reach, slot, &frame.br_dummy),
                    .CHECK, .CALL => ctx.terminalShowdown(edge, p1_reach, p2_reach, slot, &frame.br_dummy),
                    else => unreachable,
                }
            } else {
                switch (edge.action) {
                    .FOLD => ctx.terminalFold(edge, actor_isp1, p1_reach, p2_reach, &frame.br_dummy, slot),
                    .CHECK, .CALL => ctx.terminalShowdown(edge, p1_reach, p2_reach, &frame.br_dummy, slot),
                    else => unreachable,
                }
            }
        }
        {
            var v: usize = 0;
            while (v < VEC_TAIL_START) : (v += VEC_LANES) {
                var best: Vf = vload(&frame.child_cfv_p1, v);
                var a: usize = 1;
                while (a < n_actions) : (a += 1) {
                    best = @max(best, vload(&frame.child_cfv_p1, a * NUM_HANDS + v));
                }
                vstore(out_cfv, v, best);
            }
            var i: usize = VEC_TAIL_START;
            while (i < NUM_HANDS) : (i += 1) {
                var best: f32 = frame.child_cfv_p1[i];
                var a: usize = 1;
                while (a < n_actions) : (a += 1) {
                    const value = frame.child_cfv_p1[a * NUM_HANDS + i];
                    if (value > best) best = value;
                }
                out_cfv[i] = best;
            }
        }
    } else {
        // Opponent's decision: normalize strategy_sum → average strategy, scale
        // opponent's reach by it per action, and sum the child CFVs.
        // Reuses frame.strategy (same shape as avg_strategy) and the single-
        // action br_child_cfv / br_dummy slots.
        {
            const uniform: f32 = 1.0 / @as(f32, @floatFromInt(n_actions));
            const uniform_vec: Vf = @splat(uniform);
            const safe_one: Vf = @splat(1.0);
            var v: usize = 0;
            while (v < VEC_TAIL_START) : (v += VEC_LANES) {
                var sum_vec: Vf = VEC_ZERO;
                var a: usize = 0;
                while (a < n_actions) : (a += 1) {
                    sum_vec += vload(node.strategy_sum, a * NUM_HANDS + v);
                }
                const has_pos = sum_vec > VEC_ZERO;
                const safe_sum = @select(f32, has_pos, sum_vec, safe_one);
                a = 0;
                while (a < n_actions) : (a += 1) {
                    const s = vload(node.strategy_sum, a * NUM_HANDS + v);
                    const ratio = s / safe_sum;
                    vstore(&frame.strategy, a * NUM_HANDS + v, @select(f32, has_pos, ratio, uniform_vec));
                }
            }
            var i: usize = VEC_TAIL_START;
            while (i < NUM_HANDS) : (i += 1) {
                var sum: f32 = 0;
                var a: usize = 0;
                while (a < n_actions) : (a += 1) sum += node.strategy_sum[a * NUM_HANDS + i];
                if (sum > 0) {
                    a = 0;
                    while (a < n_actions) : (a += 1) {
                        frame.strategy[a * NUM_HANDS + i] = node.strategy_sum[a * NUM_HANDS + i] / sum;
                    }
                } else {
                    a = 0;
                    while (a < n_actions) : (a += 1) frame.strategy[a * NUM_HANDS + i] = uniform;
                }
            }
        }

        @memset(out_cfv, 0);
        for (node.edges, 0..) |*edge, a| {
            const off = a * NUM_HANDS;
            if (br_isp1) {
                var v: usize = 0;
                while (v < VEC_TAIL_START) : (v += VEC_LANES) {
                    vstore(&frame.new_p1_reach, v, vload(p1_reach, v));
                    vstore(&frame.new_p2_reach, v, vload(p2_reach, v) * vload(&frame.strategy, off + v));
                }
                var i: usize = VEC_TAIL_START;
                while (i < NUM_HANDS) : (i += 1) {
                    frame.new_p1_reach[i] = p1_reach[i];
                    frame.new_p2_reach[i] = p2_reach[i] * frame.strategy[off + i];
                }
            } else {
                var v: usize = 0;
                while (v < VEC_TAIL_START) : (v += VEC_LANES) {
                    vstore(&frame.new_p1_reach, v, vload(p1_reach, v) * vload(&frame.strategy, off + v));
                    vstore(&frame.new_p2_reach, v, vload(p2_reach, v));
                }
                var i: usize = VEC_TAIL_START;
                while (i < NUM_HANDS) : (i += 1) {
                    frame.new_p1_reach[i] = p1_reach[i] * frame.strategy[off + i];
                    frame.new_p2_reach[i] = p2_reach[i];
                }
            }

            if (edge.child) |child| {
                brWalk(ctx, allocator, child, &frame.new_p1_reach, &frame.new_p2_reach, br_isp1, &frame.br_child_cfv, depth + 1);
            } else if (br_isp1) {
                switch (edge.action) {
                    .FOLD => ctx.terminalFold(edge, actor_isp1, &frame.new_p1_reach, &frame.new_p2_reach, &frame.br_child_cfv, &frame.br_dummy),
                    .CHECK, .CALL => ctx.terminalShowdown(edge, &frame.new_p1_reach, &frame.new_p2_reach, &frame.br_child_cfv, &frame.br_dummy),
                    else => unreachable,
                }
            } else {
                switch (edge.action) {
                    .FOLD => ctx.terminalFold(edge, actor_isp1, &frame.new_p1_reach, &frame.new_p2_reach, &frame.br_dummy, &frame.br_child_cfv),
                    .CHECK, .CALL => ctx.terminalShowdown(edge, &frame.new_p1_reach, &frame.new_p2_reach, &frame.br_dummy, &frame.br_child_cfv),
                    else => unreachable,
                }
            }

            {
                var v: usize = 0;
                while (v < VEC_TAIL_START) : (v += VEC_LANES) {
                    vstore(out_cfv, v, vload(out_cfv, v) + vload(&frame.br_child_cfv, v));
                }
                var i: usize = VEC_TAIL_START;
                while (i < NUM_HANDS) : (i += 1) out_cfv[i] += frame.br_child_cfv[i];
            }
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
    allocator: Allocator,
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
        // Parallel workers own a fresh scratch — start from depth 0.
        brChanceWorker(self.ctx, self.allocator, self.node, self.saved_board, self.card_to_fill_idx, self.legal_cards, self.p1_reach, self.p2_reach, self.br_isp1, self.out_cfv, 0);
    }
};

// Per-card runout body shared by the serial and parallel paths of `brWalk`.
// Accumulates into `out_cfv` (additive — caller is responsible for zeroing or
// for one-shot writes). Performs no per-hand averaging; that's a single final
// pass back in `brWalk` after slot aggregation.
fn brChanceWorker(
    ctx: *SolveContext,
    allocator: Allocator,
    node: *Node,
    saved_board: [5]Card,
    card_to_fill_idx: usize,
    legal_cards: []const u32,
    p1_reach: []const f32,
    p2_reach: []const f32,
    br_isp1: bool,
    out_cfv: []f32,
    depth: usize,
) void {
    // Non-recursive itself, but recurses into brWalk per legal card. Uses
    // frames[depth] for the masked-reach + per-runout CFV buffers, then
    // recurses into brWalk at depth+1. Safe to share frames[depth] with the
    // caller because brWalk's chance branch doesn't touch its own frame
    // fields before delegating here.
    std.debug.assert(depth < MAX_WALK_DEPTH);
    const hands = ctx.solver.hand_table.all_hands;
    const frame = &ctx.scratch.frames[depth];

    for (legal_cards) |c| {
        var new_board = saved_board;
        new_board[card_to_fill_idx] = c;
        ctx.reinitForBoard(new_board);

        for (0..NUM_HANDS) |i| {
            const h = hands[i];
            const keep = !handHitsCard(h, c);
            frame.masked_p1_reach[i] = if (keep) p1_reach[i] else 0;
            frame.masked_p2_reach[i] = if (keep) p2_reach[i] else 0;
        }

        const chance_edge = &node.edges[0];
        if (chance_edge.child) |child| {
            brWalk(ctx, allocator, child, &frame.masked_p1_reach, &frame.masked_p2_reach, br_isp1, &frame.br_child_cfv, depth + 1);
        } else if (br_isp1) {
            ctx.terminalShowdown(chance_edge, &frame.masked_p1_reach, &frame.masked_p2_reach, &frame.br_child_cfv, &frame.br_dummy);
        } else {
            ctx.terminalShowdown(chance_edge, &frame.masked_p1_reach, &frame.masked_p2_reach, &frame.br_dummy, &frame.br_child_cfv);
        }

        for (0..NUM_HANDS) |i| {
            const h = hands[i];
            if (handHitsCard(h, c)) continue;
            out_cfv[i] += frame.br_child_cfv[i];
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

pub fn bestResponse(self: *Solver, allocator: Allocator, root: *Node, br_isp1: bool, out_cfv: []f32) !void {
    var scratch = try WalkScratch.init(allocator);
    defer scratch.deinit(allocator);
    var ctx = SolveContext.initOnSolver(self, &scratch);
    bestResponseWith(&ctx, allocator, root, br_isp1, out_cfv);
}

/// Ctx-taking BR entry point. The reach vectors live on the Solver (immutable)
/// so a caller-owned SolveContext over a separate BoardContext can run on its
/// own thread without colliding with another worker.
pub fn bestResponseWith(ctx: *SolveContext, allocator: Allocator, root: *Node, br_isp1: bool, out_cfv: []f32) void {
    brWalk(ctx, allocator, root, &ctx.solver.p1_reach, &ctx.solver.p2_reach, br_isp1, out_cfv, 0);
}

const BrJob = struct {
    ctx: *SolveContext,
    allocator: Allocator,
    root: *Node,
    br_isp1: bool,
    out_cfv: []f32,

    fn run(self: BrJob) void {
        bestResponseWith(self.ctx, self.allocator, self.root, self.br_isp1, self.out_cfv);
    }
};

// Sum of best-response values for both players, weighted by their reach. At a
// Nash equilibrium this is zero (zero-sum game); any positive value is how
// much can be extracted by exploiting the current average strategies.
//
// The two BR walks are independent and run on two threads. Each thread gets
// its own SolveContext over its own BoardContext copy and its own WalkScratch
// so neither side's chance enumeration corrupts the other's state.
pub fn exploitability(self: *Solver, allocator: Allocator, root: *Node) !f32 {
    var br_p1: [NUM_HANDS]f32 = undefined;
    var br_p2: [NUM_HANDS]f32 = undefined;

    var board_a: BoardContext = self.board_ctx;
    var board_b: BoardContext = self.board_ctx;

    var scratch_a = try WalkScratch.init(allocator);
    defer scratch_a.deinit(allocator);
    var scratch_b = try WalkScratch.init(allocator);
    defer scratch_b.deinit(allocator);

    var ctx_a = SolveContext.initOnBoardContext(self, &board_a, &scratch_a);
    var ctx_b = SolveContext.initOnBoardContext(self, &board_b, &scratch_b);

    const job_a = BrJob{ .ctx = &ctx_a, .allocator = allocator, .root = root, .br_isp1 = true, .out_cfv = &br_p1 };
    const job_b = BrJob{ .ctx = &ctx_b, .allocator = allocator, .root = root, .br_isp1 = false, .out_cfv = &br_p2 };

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

    var empty_scratch_a = WalkScratch.empty;
    var empty_scratch_b = WalkScratch.empty;
    const ctx_a = SolveContext.initOnSolver(&solver, &empty_scratch_a);
    var ctx_b = SolveContext.initOnBoardContext(&solver, &worker_b_board, &empty_scratch_b);

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
    const expl = try exploitability(&solver, temp_allocator, root);
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

    const expl = try exploitability(&solver, temp_allocator, root);
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

    // Run enough iterations for DCFR's regret matching to learn that AA should
    // not fold — chance-sampled river cards mean a single iter's cfv can swing
    // either way, so we average over more samples here.
    var prng = std.Random.DefaultPrng.init(42);
    try solve(&solver, temp_allocator, root, 100, prng.random(), &cfv_p1, &cfv_p2);

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
    var scratch = try WalkScratch.init(std.testing.allocator);
    defer scratch.deinit(std.testing.allocator);
    var ctx = SolveContext.initOnSolver(&solver, &scratch);
    walk(&ctx, &leaf_node, &solver.p1_reach, &solver.p2_reach, &cfv_p1, &cfv_p2, prng.random(), DcfrWeights.forIter(0), null, 0);

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
    var scratch = try WalkScratch.init(std.testing.allocator);
    defer scratch.deinit(std.testing.allocator);
    var ctx = SolveContext.initOnSolver(&solver, &scratch);
    brWalk(&ctx, std.testing.allocator, &chance_node, &solver.p1_reach, &solver.p2_reach, true, &cfv, 0);

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
    var scratch = try WalkScratch.init(std.testing.allocator);
    defer scratch.deinit(std.testing.allocator);
    var ctx = SolveContext.initOnSolver(&solver, &scratch);
    brWalk(&ctx, std.testing.allocator, &turn_chance, &solver.p1_reach, &solver.p2_reach, true, &exact_p1, 0);
    brWalk(&ctx, std.testing.allocator, &turn_chance, &solver.p1_reach, &solver.p2_reach, false, &exact_p2, 0);

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

test "Solver.solve: turn-start with scratch pool — deeper recursion stays deterministic" {
    // Regression for the heap-allocated WalkScratch: turn-start trees have
    // chance-node recursion that exercises masked_p1_reach/masked_p2_reach
    // slots at depth > 0, where any bug in the depth-indexing scheme (e.g.
    // sharing the same frame index across recursive levels) would
    // immediately corrupt downstream computations. Two solves with the
    // same seed and worker count must still produce bit-identical CFVs and
    // regrets at this deeper tree shape.
    var da = std.heap.DebugAllocator(.{}){};
    defer _ = da.deinit();
    const temp_allocator = da.allocator();

    var arena_a = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_a.deinit();
    var arena_b = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_b.deinit();

    // Turn board, river slot empty so the tree includes a turn → river
    // chance node and recursive walk descends across the chance transition.
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

    const runOnce = struct {
        fn run(allocator: Allocator, arena_alloc: Allocator, b: [5]Card, aa: u16, kk: u16, out_p1: *[NUM_HANDS]f32, out_p2: *[NUM_HANDS]f32) ![]f32 {
            var state = gamestate_mod.GameState.init(.TURN, true, 50, 100, 100);
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

            var prng = std.Random.DefaultPrng.init(0xBEEF);
            try solve(&solver, allocator, root, 20, prng.random(), out_p1, out_p2);

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

    try std.testing.expectEqual(cfv_a_p1[aa_idx], cfv_b_p1[aa_idx]);
    try std.testing.expectEqual(cfv_a_p2[kk_idx], cfv_b_p2[kk_idx]);
    try std.testing.expectEqual(regrets_a.len, regrets_b.len);
    for (regrets_a, regrets_b) |a, b| try std.testing.expectEqual(a, b);
}

test "DcfrWeights.forIter: known values at t=1, t=2" {
    // t = 1 (iter index 0): t^α = 1, so pos_discount = 1/2. β=0 ⇒ neg = 1/2.
    // (t/(t+1))^γ = (1/2)² = 0.25.
    const w0 = DcfrWeights.forIter(0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), w0.regret_pos_discount, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), w0.regret_neg_discount, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), w0.strategy_sum_discount, 1e-5);

    // t = 2: t^1.5 ≈ 2.8284; pos_discount = 2.8284 / 3.8284 ≈ 0.7388.
    // (t/(t+1))^γ = (2/3)² ≈ 0.4444.
    const w1 = DcfrWeights.forIter(1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7388), w1.regret_pos_discount, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), w1.regret_neg_discount, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4444), w1.strategy_sum_discount, 1e-3);
}

test "DCFR: river polarized strategy converges to a stable equilibrium" {
    // Reuses the bench's `river-polarized` shape but with a smaller iter count.
    // The expectation is the convergence regression guard: with DCFR's regret
    // discounts the polarized P1 strategy on (AA / KK / 56-bluff) should
    // settle into a recognizable bet-heavy line, not bounce between extremes.
    const allocator = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const board = [5]Card{
        card_mod.makeCard(12, 0),
        card_mod.makeCard(11, 0),
        card_mod.makeCard(0, 1),
        card_mod.makeCard(1, 2),
        card_mod.makeCard(5, 3),
    };

    const ht = HandTable.init();
    const aa_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 1), card_mod.makeCard(12, 2))).?;
    const kk_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(11, 1), card_mod.makeCard(11, 2))).?;
    const bluff_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(5, 0), card_mod.makeCard(0, 3))).?;

    var p1 = try Range.initEmpty(allocator, 3);
    defer p1.deinit(allocator);
    p1.active_indices[0] = aa_idx;
    p1.active_indices[1] = kk_idx;
    p1.active_indices[2] = bluff_idx;
    p1.probs[0] = 0.2;
    p1.probs[1] = 0.2;
    p1.probs[2] = 0.6;
    p1.normalize();

    const t1_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 1), card_mod.makeCard(10, 2))).?;
    const t2_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 1), card_mod.makeCard(9, 2))).?;
    const t3_idx = ht.getIndex(range_mod.Hand.init(card_mod.makeCard(12, 1), card_mod.makeCard(8, 2))).?;
    var p2 = try Range.initEmpty(allocator, 3);
    defer p2.deinit(allocator);
    p2.active_indices[0] = t1_idx;
    p2.active_indices[1] = t2_idx;
    p2.active_indices[2] = t3_idx;
    p2.probs[0] = 0.33;
    p2.probs[1] = 0.33;
    p2.probs[2] = 0.34;
    p2.normalize();

    var root_state = gamestate_mod.GameState.init(.RIVER, true, 100, 500, 500);
    var arr = std.ArrayList(Edge).empty;
    defer arr.deinit(allocator);
    try node_mod.buildTree(&root_state, &arr, arena_allocator, allocator, NUM_HANDS, NUM_HANDS);
    const root = arr.items[0].child.?;
    _ = node_mod.assignIds(root);

    var solver = try Solver.init(std.testing.io, board, &p1, &p2, 500, 500, 100);
    defer solver.deinit();
    solver.max_workers = 1; // Deterministic serial path.

    var cfv_p1: [NUM_HANDS]f32 = undefined;
    var cfv_p2: [NUM_HANDS]f32 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    try solve(&solver, allocator, root, 200, prng.random(), &cfv_p1, &cfv_p2);

    // AA at the root must NOT fold (it never has to; it's always at showdown
    // ahead of the call range). The fold edge is index 0 only if a bet exists;
    // at the root P1 acts first, so its actions are check + bets + all-in. We
    // verify the *average* strategy: AA's check frequency should not be 100%.
    // Equivalently, the bet-with-AA frequency should be > 0 in the strategy
    // sum.
    var aa_total: f32 = 0;
    var aa_bet_mass: f32 = 0;
    for (root.edges, 0..) |edge, a| {
        const v = root.strategy_sum[a * NUM_HANDS + aa_idx];
        aa_total += v;
        if (edge.action == .BET or edge.action == .ALLIN) aa_bet_mass += v;
    }
    try std.testing.expect(aa_total > 0);
    const aa_bet_freq = aa_bet_mass / aa_total;
    // AA value-bets the polarized river: bet/all-in freq should be a clear
    // majority of the averaged strategy after DCFR converges.
    try std.testing.expect(aa_bet_freq > 0.5);

    // Bluff (76o on the AKxxx board) should have a different distribution
    // than AA — DCFR's regret matching should produce a non-degenerate
    // strategy for it (not 1/n on every action). Concretely: its strategy
    // should differ from AA's by more than rounding.
    var bluff_total: f32 = 0;
    var bluff_bet_mass: f32 = 0;
    for (root.edges, 0..) |edge, a| {
        const v = root.strategy_sum[a * NUM_HANDS + bluff_idx];
        bluff_total += v;
        if (edge.action == .BET or edge.action == .ALLIN) bluff_bet_mass += v;
    }
    try std.testing.expect(bluff_total > 0);
    const bluff_bet_freq = bluff_bet_mass / bluff_total;
    // Bluff's bet frequency should not be exactly equal to AA's — confirms
    // regret matching is learning hand-specific strategies, not uniform.
    try std.testing.expect(@abs(bluff_bet_freq - aa_bet_freq) > 0.05);
}
