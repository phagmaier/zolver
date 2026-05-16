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
// bet: {fold, call, all-in, 2 raise sizes} = 5. Round up for headroom.
const MAX_ACTIONS: usize = 6;

// River-first solver. Holds the static showdown environment (precomputed hand
// strengths against a fixed 5-card board, blocker mask) plus the dense reach
// vectors used during CFR traversal. Solve loop, terminal payoffs, and the
// recursive walker are added in subsequent steps.
pub const Solver = struct {
    evaluator: Evaluator,
    hand_table: HandTable,
    board: [5]Card,

    // Stack/pot baseline at the solver root — needed at terminals to recover
    // each player's contribution since root via (initial_stack - edge.stack).
    initial_stack1: f32,
    initial_stack2: f32,
    pot_at_root: f32,

    // Precomputed at init.
    hand_strengths: [NUM_HANDS]u32,
    blocked: [NUM_HANDS]bool,

    // Dense reach vectors derived from the caller's sparse Range inputs.
    // Indexed by hand id 0..1325; blocked entries are zero.
    p1_reach: [NUM_HANDS]f32,
    p2_reach: [NUM_HANDS]f32,

    pub fn init(
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
            .board = board,
            .initial_stack1 = initial_stack1,
            .initial_stack2 = initial_stack2,
            .pot_at_root = pot_at_root,
            .hand_strengths = undefined,
            .blocked = undefined,
            .p1_reach = undefined,
            .p2_reach = undefined,
        };

        @memset(&self.p1_reach, 0);
        @memset(&self.p2_reach, 0);

        for (self.hand_table.all_hands, 0..) |hand, i| {
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
                    board[0],   board[1], board[2], board[3], board[4],
                };
                self.hand_strengths[i] = self.evaluator.handStrength(seven);
            }
        }

        for (p1.active_indices, p1.probs) |idx, p| {
            if (!self.blocked[idx]) self.p1_reach[idx] = p;
        }
        for (p2.active_indices, p2.probs) |idx, p| {
            if (!self.blocked[idx]) self.p2_reach[idx] = p;
        }

        return self;
    }

    pub fn deinit(self: *Solver) void {
        self.evaluator.deinit();
    }

    // EV at a fold terminal. The pot goes to whoever didn't fold; the folder's
    // effective contribution since solver root drives the per-hand payoff.
    // Both per-hand counterfactual value vectors (cfv_p1[i], cfv_p2[j]) get the
    // payoff weighted by the *opponent's* reach mass that doesn't share cards.
    pub fn terminalFold(
        self: *const Solver,
        edge: *const Edge,
        folder_isp1: bool,
        p1_reach: []const f32,
        p2_reach: []const f32,
        out_cfv_p1: []f32,
        out_cfv_p2: []f32,
    ) void {
        const eff_c1 = (self.initial_stack1 - edge.stack1) + self.pot_at_root / 2.0;
        const eff_c2 = (self.initial_stack2 - edge.stack2) + self.pot_at_root / 2.0;
        const folder_loss: f32 = if (folder_isp1) eff_c1 else eff_c2;
        const p1_payoff: f32 = if (folder_isp1) -folder_loss else folder_loss;
        const p2_payoff: f32 = -p1_payoff;

        @memset(out_cfv_p1, 0);
        @memset(out_cfv_p2, 0);

        var i: usize = 0;
        while (i < NUM_HANDS) : (i += 1) {
            if (self.blocked[i]) continue;
            const hand_i = self.hand_table.all_hands[i];
            var j: usize = 0;
            while (j < NUM_HANDS) : (j += 1) {
                if (self.blocked[j]) continue;
                const hand_j = self.hand_table.all_hands[j];
                if (!handsCompatible(hand_i, hand_j)) continue;
                out_cfv_p1[i] += p2_reach[j] * p1_payoff;
                out_cfv_p2[j] += p1_reach[i] * p2_payoff;
            }
        }
    }

    // EV at a showdown terminal. Each side has matched bets at this point, so
    // both effective contributions equal half the pot; winner of (i vs j) gains
    // half_pot, loser loses it, ties are zero. Output is per-hand CFV for both.
    pub fn terminalShowdown(
        self: *const Solver,
        edge: *const Edge,
        p1_reach: []const f32,
        p2_reach: []const f32,
        out_cfv_p1: []f32,
        out_cfv_p2: []f32,
    ) void {
        const half_pot: f32 = edge.amount / 2.0;

        @memset(out_cfv_p1, 0);
        @memset(out_cfv_p2, 0);

        var i: usize = 0;
        while (i < NUM_HANDS) : (i += 1) {
            if (self.blocked[i]) continue;
            const hand_i = self.hand_table.all_hands[i];
            const s_i = self.hand_strengths[i];
            var j: usize = 0;
            while (j < NUM_HANDS) : (j += 1) {
                if (self.blocked[j]) continue;
                const hand_j = self.hand_table.all_hands[j];
                if (!handsCompatible(hand_i, hand_j)) continue;
                const s_j = self.hand_strengths[j];
                const p1_payoff: f32 = if (s_i > s_j) half_pot else if (s_i < s_j) -half_pot else 0;
                out_cfv_p1[i] += p2_reach[j] * p1_payoff;
                out_cfv_p2[j] -= p1_reach[i] * p1_payoff;
            }
        }
    }
};

inline fn handsCompatible(a: range_mod.Hand, b: range_mod.Hand) bool {
    return a.card1 != b.card1 and a.card1 != b.card2 and a.card2 != b.card1 and a.card2 != b.card2;
}

// Run vanilla vector-CFR for the given number of iterations. The dense reach
// vectors (solver.p1_reach / p2_reach) seed the traversal; out buffers receive
// the per-hand counterfactual values from the *last* iteration's walk.
pub fn solve(
    self: *Solver,
    root: *Node,
    iterations: usize,
    out_cfv_p1: []f32,
    out_cfv_p2: []f32,
) void {
    var iter: usize = 0;
    while (iter < iterations) : (iter += 1) {
        walk(self, root, &self.p1_reach, &self.p2_reach, out_cfv_p1, out_cfv_p2);
    }
}

// Single recursive pass. Computes per-hand CFV for both players, then updates
// the acting player's regrets and strategy_sum using vanilla CFR's update rule.
// Both players' regret tables get updated across the full walk (one iteration
// = one tree traversal), since each decision node belongs to exactly one of
// them and only that player's tables get touched there.
fn walk(
    self: *Solver,
    node: *Node,
    p1_reach: []const f32,
    p2_reach: []const f32,
    out_cfv_p1: []f32,
    out_cfv_p2: []f32,
) void {
    if (node.is_chance) unreachable; // Chance nodes handled in step 7.

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
            walk(self, child, &new_p1_reach, &new_p2_reach, cfv_p1_slot, cfv_p2_slot);
        } else {
            switch (edge.action) {
                .FOLD => self.terminalFold(edge, actor_isp1, &new_p1_reach, &new_p2_reach, cfv_p1_slot, cfv_p2_slot),
                .CHECK, .CALL => self.terminalShowdown(edge, &new_p1_reach, &new_p2_reach, cfv_p1_slot, cfv_p2_slot),
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
    if (actor_isp1) {
        var a: usize = 0;
        while (a < n_actions) : (a += 1) {
            const off = a * NUM_HANDS;
            var i: usize = 0;
            while (i < NUM_HANDS) : (i += 1) {
                node.regrets[off + i] += child_cfv_p1[off + i] - out_cfv_p1[i];
                node.strategy_sum[off + i] += p1_reach[i] * strategy[off + i];
            }
        }
    } else {
        var a: usize = 0;
        while (a < n_actions) : (a += 1) {
            const off = a * NUM_HANDS;
            var i: usize = 0;
            while (i < NUM_HANDS) : (i += 1) {
                node.regrets[off + i] += child_cfv_p2[off + i] - out_cfv_p2[i];
                node.strategy_sum[off + i] += p2_reach[i] * strategy[off + i];
            }
        }
    }
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

    var solver = try Solver.init(board, &p1, &p2, 1000, 1000, 100);
    defer solver.deinit();

    // Total hands collide-free with 5 board cards = C(47,2) = 1081 → 1326 - 1081 = 245 blocked.
    var blocked_count: usize = 0;
    for (solver.blocked) |b| {
        if (b) blocked_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 245), blocked_count);

    try std.testing.expect(solver.blocked[blocked_idx]);
    try std.testing.expect(!solver.blocked[safe_idx]);
    try std.testing.expectEqual(@as(u32, 0), solver.hand_strengths[blocked_idx]);
    try std.testing.expect(solver.hand_strengths[safe_idx] > 0);

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

    var solver = try Solver.init(board, &p1, &p2, 1000, 1000, 0);
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

    var solver = try Solver.init(board, &p1, &p2, 1000, 1000, 0);
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

    var solver = try Solver.init(board, &p1, &p2, 100, 100, 50);
    defer solver.deinit();

    var cfv_p1: [NUM_HANDS]f32 = undefined;
    var cfv_p2: [NUM_HANDS]f32 = undefined;
    solve(&solver, root, 200, &cfv_p1, &cfv_p2);

    // AA always beats KK on this board. At NE p2 folds to any p1 bet and p1
    // can also just check it down — either way p1's root CFV is exactly +25
    // (half of the unraised pot OR the folder's effective contribution).
    try std.testing.expectApproxEqAbs(@as(f32, 25), cfv_p1[aa_idx], 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, -25), cfv_p2[kk_idx], 0.5);
}
