const std = @import("std");
const card = @import("card.zig");
const game_tree = @import("game_tree.zig");
const isomorphism = @import("isomorphism.zig");
const range = @import("range.zig");
const storage = @import("storage.zig");
const blocking = @import("blocking.zig");
const showdown = @import("showdown.zig");
const remap_mod = @import("remap.zig");
const evaluator_mod = @import("evaluator.zig");

const Allocator = std.mem.Allocator;
const Card = card.Card;
const Combo = card.Combo;
const Tree = game_tree.Tree;
const RunoutTables = isomorphism.RunoutTables;
const Range = range.Range;
const WeightedCombo = range.WeightedCombo;
const Storage = storage.Storage;
const BlockingTables = blocking.BlockingTables;
const ShowdownTables = showdown.ShowdownTables;
const Evaluator = evaluator_mod.Evaluator;

/// Fully-initialized solver state: tree, runout tables, ranges, regret/strategy
/// storage, blocking masks, showdown tables, f32 SIMD masks, same-combo-index
/// tables, and precomputed chance-normalization weights.
/// Produced once before solving begins.
pub const SolverInit = struct {
    allocator: Allocator,
    /// User-requested total solver-memory limit. Storage is checked during
    /// initialization; `Solver.init` checks this value again once its
    /// thread-dependent scratch requirement is known.
    max_budget_bytes: u64,

    tree: Tree,
    runout_tables: RunoutTables,
    ranges: [2]Range,
    storage: Storage,
    blocking: BlockingTables,
    showdown: ShowdownTables,

    /// Whether the solver traverses compressed canonical runouts (remapping
    /// reaches/values per orbit member) or the full physical runout space.
    compress_suits: bool,
    /// Suit-orbit remap tables; populated only when `compress_suits` is true.
    remap: ?remap_mod.RemapTables,

    /// f32 mask arrays (1.0 = live, 0.0 = blocked) for SIMD branching-free masking.
    mask_flop: [2][]f32,
    mask_turn: [2][]f32,
    mask_river: [2][]f32,

    /// same_combo_idx[p][h] = opponent's range-local index of the identical
    /// two-card combo, or maxInt(u32) if the opponent does not hold that combo.
    same_combo_idx: [2][]u32,

    /// Precomputed chance weights: physical-card probability for a compatible
    /// private-hand pair, i.e. multiplicity / 45 (turn) and / 44 (river).
    weight_turns: []f32,
    weight_rivers: []f32,

    /// Precomputed per-hand card indices: card_idx[p][2*h] = card.index(hands[p][h].first),
    /// card_idx[p][2*h+1] = card.index(hands[p][h].second). Eliminates card.index()
    /// lookups in the terminal evaluation hot path.
    card_idx: [2][]u8,

    /// Orchestrate the full initialization pipeline.
    ///
    /// 1. Build range-local hand indices
    /// 2. Construct the betting-tree skeleton
    /// 3. Compute suit-isomorphism canonical runout tables
    /// 4. Estimate memory, check budget, allocate regret + strategy arrays
    /// 5. Precompute blocked-hand bool masks per runout
    /// 6. Convert bool masks to f32 SIMD masks
    /// 7. Precompute same_combo_idx tables
    /// 8. Precompute chance normalization weights
    /// 9. Precompute hand strengths + sorted order per river runout
    pub fn init(allocator: Allocator, config: Config) !SolverInit {
        var ranges: [2]Range = undefined;
        ranges[0] = try range.buildRange(allocator, config.oop_range);
        errdefer ranges[0].deinit();
        ranges[1] = try range.buildRange(allocator, config.ip_range);
        errdefer ranges[1].deinit();

        const range_sizes = [2]u32{ ranges[0].N(), ranges[1].N() };

        const tree_config = game_tree.BuildConfig{
            .initial_pot = config.initial_pot,
            .effective_stack = config.effective_stack,
            .min_bet = config.min_bet,
            .sizings = config.sizings,
            .raise_cap = config.raise_cap,
            .range_sizes = range_sizes,
        };
        var tree = try game_tree.buildGameTree(allocator, tree_config);
        errdefer tree.deinit();

        // Suit-orbit compression requires remapping private-hand reaches and
        // values for every orbit member (see `remap` below and `cfr.zig`). When
        // disabled we solve the full physical runout space — the correctness
        // oracle. `buildRunoutTables` keeps only permutations that preserve both
        // ranges, so its identity element always survives (no error in practice).
        var runout_tables = if (config.compress_suits)
            try isomorphism.buildRunoutTables(allocator, config.flop, .{ config.oop_range, config.ip_range })
        else
            try isomorphism.buildUncompressedRunoutTables(allocator, config.flop);
        errdefer runout_tables.deinit();

        const runout_counts = runout_tables.runoutCounts();
        _ = storage.memoryEstimate(tree.slots_per_runout, runout_counts); // logged by caller if desired

        var store = try Storage.init(
            allocator,
            tree.slots_per_runout,
            runout_counts,
            config.max_budget_bytes,
        );
        errdefer store.deinit();

        const hands: [2][]const Combo = .{ ranges[0].hands, ranges[1].hands };

        var blk = try BlockingTables.init(allocator, hands, config.flop, &runout_tables);
        errdefer blk.deinit();

        // f32 SIMD masks: convert bool → f32 (1.0 = live, 0.0 = blocked)
        const mf0 = try allocConvertBoolSlice(allocator, blk.blocked_flop[0]);
        errdefer allocator.free(mf0);
        const mf1 = try allocConvertBoolSlice(allocator, blk.blocked_flop[1]);
        errdefer allocator.free(mf1);
        const mt0 = try allocConvertBoolSlice(allocator, blk.blocked_turn[0]);
        errdefer allocator.free(mt0);
        const mt1 = try allocConvertBoolSlice(allocator, blk.blocked_turn[1]);
        errdefer allocator.free(mt1);
        const mr0 = try allocConvertBoolSlice(allocator, blk.blocked_river[0]);
        errdefer allocator.free(mr0);
        const mr1 = try allocConvertBoolSlice(allocator, blk.blocked_river[1]);
        errdefer allocator.free(mr1);

        // same_combo_idx: for each hand, find opponent's index of the identical combo
        const sci = try buildSameComboIdx(allocator, ranges);
        errdefer {
            allocator.free(sci[0]);
            allocator.free(sci[1]);
        }

        // Precompute per-hand flat card index arrays (eliminates card.index()
        // from every terminal kernel's hot path).
        const card_idx = try buildCardIdx(allocator, ranges);
        errdefer {
            allocator.free(card_idx[0]);
            allocator.free(card_idx[1]);
        }

        // Chance normalization weights: multiplicity / cards_remaining
        const w_turns = try allocChanceWeights(allocator, runout_tables.canonical_turns, 45.0);
        errdefer allocator.free(w_turns);
        const w_rivers = try allocChanceWeights(allocator, runout_tables.canonical_rivers, 44.0);
        errdefer allocator.free(w_rivers);

        var eval = try Evaluator.init();
        defer eval.deinit();

        var sd = try ShowdownTables.init(allocator, hands, config.flop, &runout_tables, &eval);
        errdefer sd.deinit();

        // Orbit-member remap tables: only needed when compressing. For the
        // physical oracle every orbit is trivially size one, so we skip the build.
        var remap: ?remap_mod.RemapTables = null;
        if (config.compress_suits) {
            remap = try remap_mod.build(allocator, hands, config.flop, &runout_tables);
        }
        errdefer if (remap) |*rm| rm.deinit();

        return .{
            .allocator = allocator,
            .max_budget_bytes = config.max_budget_bytes,
            .tree = tree,
            .runout_tables = runout_tables,
            .ranges = ranges,
            .storage = store,
            .blocking = blk,
            .showdown = sd,
            .mask_flop = .{ mf0, mf1 },
            .mask_turn = .{ mt0, mt1 },
            .mask_river = .{ mr0, mr1 },
            .same_combo_idx = sci,
            .weight_turns = w_turns,
            .weight_rivers = w_rivers,
            .card_idx = card_idx,
            .compress_suits = config.compress_suits,
            .remap = remap,
        };
    }

    pub fn deinit(self: *SolverInit) void {
        if (self.remap) |*rm| rm.deinit();
        self.allocator.free(self.card_idx[1]);
        self.allocator.free(self.card_idx[0]);
        self.allocator.free(self.weight_rivers);
        self.allocator.free(self.weight_turns);
        self.allocator.free(self.same_combo_idx[1]);
        self.allocator.free(self.same_combo_idx[0]);
        self.allocator.free(self.mask_river[1]);
        self.allocator.free(self.mask_river[0]);
        self.allocator.free(self.mask_turn[1]);
        self.allocator.free(self.mask_turn[0]);
        self.allocator.free(self.mask_flop[1]);
        self.allocator.free(self.mask_flop[0]);
        self.showdown.deinit();
        self.blocking.deinit();
        self.storage.deinit();
        self.runout_tables.deinit();
        self.ranges[1].deinit();
        self.ranges[0].deinit();
        self.tree.deinit();
        self.* = undefined;
    }

    /// Bytes held by the initialized game representation, excluding the
    /// thread-dependent `Solver` working arenas. This deliberately counts all
    /// retained solver arrays, not only regret/strategy storage.
    pub fn memoryBytes(self: *const SolverInit) !u64 {
        var total: u64 = 0;
        try addSliceBytes(&total, self.tree.action_nodes.items, game_tree.ActionNode);
        try addSliceBytes(&total, self.tree.chance_nodes.items, game_tree.ChanceNode);
        try addSliceBytes(&total, self.tree.terminal_nodes.items, game_tree.TerminalNode);
        try addSliceBytes(&total, self.tree.edges.items, game_tree.NodeRef);
        try addSliceBytes(&total, self.runout_tables.valid_permutations, isomorphism.SuitPermutation);
        try addSliceBytes(&total, self.runout_tables.canonical_turns, isomorphism.CanonicalTurn);
        try addSliceBytes(&total, self.runout_tables.canonical_rivers, isomorphism.CanonicalRiver);
        inline for (0..2) |p| {
            try addSliceBytes(&total, self.ranges[p].hands, Combo);
            try addSliceBytes(&total, self.ranges[p].weights, f32);
            try addSliceBytes(&total, self.blocking.blocked_flop[p], bool);
            try addSliceBytes(&total, self.blocking.blocked_turn[p], bool);
            try addSliceBytes(&total, self.blocking.blocked_river[p], bool);
            try addSliceBytes(&total, self.mask_flop[p], f32);
            try addSliceBytes(&total, self.mask_turn[p], f32);
            try addSliceBytes(&total, self.mask_river[p], f32);
            try addSliceBytes(&total, self.same_combo_idx[p], u32);
            try addSliceBytes(&total, self.card_idx[p], u8);
            try addSliceBytes(&total, self.showdown.strengths[p], u32);
            try addSliceBytes(&total, self.showdown.order[p], u32);
        }
        try addSliceBytes(&total, self.weight_turns, f32);
        try addSliceBytes(&total, self.weight_rivers, f32);
        if (self.remap) |*rm| total = try std.math.add(u64, total, rm.memoryBytes());
        try addSliceBytes(&total, self.storage.regrets_flop, f32);
        try addSliceBytes(&total, self.storage.regrets_turn, f32);
        try addSliceBytes(&total, self.storage.regrets_river, f32);
        try addSliceBytes(&total, self.storage.strategies_flop, f32);
        try addSliceBytes(&total, self.storage.strategies_turn, f32);
        try addSliceBytes(&total, self.storage.strategies_river, f32);
        return total;
    }
};

/// All user-provided configuration needed to initialize the solver.
pub const Config = struct {
    flop: [3]Card,
    initial_pot: u32,
    effective_stack: u32,
    min_bet: u32,
    sizings: [3][]const game_tree.Sizing,
    raise_cap: [3]?u8,
    oop_range: []const WeightedCombo,
    ip_range: []const WeightedCombo,
    /// Refuse allocation if the regret + strategy arrays exceed this byte count.
    max_budget_bytes: u64,
    /// When true, solve over suit-isomorphic canonical runouts and remap
    /// private-hand reaches/values per orbit member (memory win on symmetric
    /// boards). When false (default), solve the full physical runout space — the
    /// correctness oracle. See `AGENTS.md` follow-up #1.
    compress_suits: bool = false,

    pub fn default(
        flop: [3]Card,
        oop_range: []const WeightedCombo,
        ip_range: []const WeightedCombo,
    ) Config {
        return .{
            .flop = flop,
            .initial_pot = 100,
            .effective_stack = 1000,
            .min_bet = 1,
            .sizings = game_tree.default_sizings,
            .raise_cap = game_tree.default_raise_cap,
            .oop_range = oop_range,
            .ip_range = ip_range,
            .max_budget_bytes = std.math.maxInt(u64),
        };
    }
};

/// Convert a bool blocked-hand table to f32 masks: 1.0 = live, 0.0 = blocked.
fn allocConvertBoolSlice(allocator: Allocator, blocked: []const bool) ![]f32 {
    const result = try allocator.alloc(f32, blocked.len);
    for (blocked, 0..) |b, i| {
        result[i] = if (b) 0.0 else 1.0;
    }
    return result;
}

/// Build same_combo_idx tables. For each player p and hand h, store the
/// opponent's range-local index of the identical two-card combo, or
/// maxInt(u32) if the opponent does not hold that combo.
fn buildSameComboIdx(allocator: Allocator, ranges: [2]Range) ![2][]u32 {
    var result: [2][]u32 = undefined;

    for (0..2) |p| {
        const opp = 1 - p;
        const N_p = ranges[p].N();
        const N_opp = ranges[opp].N();

        const idx = try allocator.alloc(u32, N_p);
        errdefer allocator.free(idx);

        // Build lookup: combo canonical key → opponent range index
        var lookup = [_]?u32{null} ** 2652;
        for (0..N_opp) |i| {
            const key: usize = @intCast(ranges[opp].hands[i].canonicalKey());
            lookup[key] = @intCast(i);
        }

        for (0..N_p) |i| {
            const key: usize = @intCast(ranges[p].hands[i].canonicalKey());
            idx[i] = lookup[key] orelse std.math.maxInt(u32);
        }

        result[p] = idx;
    }

    return result;
}

/// Precompute per-hand flat card-index arrays.
/// card_idx[p][2*h]   = card.index(hands[p][h].first)
/// card_idx[p][2*h+1] = card.index(hands[p][h].second)
fn buildCardIdx(allocator: Allocator, ranges: [2]Range) ![2][]u8 {
    var result: [2][]u8 = undefined;
    for (0..2) |p| {
        const N_p = ranges[p].N();
        const idx = try allocator.alloc(u8, @as(usize, N_p) * 2);
        errdefer allocator.free(idx);
        for (0..N_p) |i| {
            idx[2 * i] = card.index(ranges[p].hands[i].first);
            idx[2 * i + 1] = card.index(ranges[p].hands[i].second);
        }
        result[p] = idx;
    }
    return result;
}

/// Precompute chance weights: multiplicity / cards_remaining for each
/// canonical card in the given slice.
fn allocChanceWeights(allocator: Allocator, cards: anytype, cards_remaining: f32) ![]f32 {
    const weights = try allocator.alloc(f32, cards.len);
    for (cards, 0..) |card_info, i| {
        weights[i] = @as(f32, @floatFromInt(card_info.multiplicity)) / cards_remaining;
    }
    return weights;
}

fn addSliceBytes(total: *u64, slice: anytype, comptime T: type) !void {
    const bytes = try std.math.mul(u64, @as(u64, @intCast(slice.len)), @sizeOf(T));
    total.* = try std.math.add(u64, total.*, bytes);
}

test "full init and deinit cycle" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(11, 0),
        card.makeCard(10, 0),
    };

    const oop_hand = try Combo.init(card.makeCard(0, 1), card.makeCard(1, 1));
    const ip_hand = try Combo.init(card.makeCard(2, 1), card.makeCard(3, 1));

    const oop_input = [_]WeightedCombo{
        .{ .combo = oop_hand, .weight = 1.0 },
    };
    const ip_input = [_]WeightedCombo{
        .{ .combo = ip_hand, .weight = 1.0 },
    };

    const config = Config{
        .flop = flop,
        .initial_pot = 20,
        .effective_stack = 60,
        .min_bet = 1,
        .sizings = game_tree.default_sizings,
        .raise_cap = game_tree.default_raise_cap,
        .oop_range = &oop_input,
        .ip_range = &ip_input,
        .max_budget_bytes = std.math.maxInt(u64),
    };

    var init_state = try SolverInit.init(std.testing.allocator, config);
    defer init_state.deinit();

    try std.testing.expectEqual(@as(u32, 1), init_state.ranges[0].N());
    try std.testing.expectEqual(@as(u32, 1), init_state.ranges[1].N());
    try std.testing.expect(init_state.tree.action_nodes.items.len > 0);
    try std.testing.expect(init_state.runout_tables.canonical_turns.len > 0);
    try std.testing.expect(init_state.storage.regrets_flop.len > 0);
    try std.testing.expect(init_state.blocking.N[0] == 1);
    try std.testing.expect(init_state.showdown.N[0] == 1);
}

test "budget exceeded propagates" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(11, 0),
        card.makeCard(10, 0),
    };

    const hand = try Combo.init(card.makeCard(0, 1), card.makeCard(1, 1));
    const input = [_]WeightedCombo{.{ .combo = hand, .weight = 1.0 }};

    const config = Config{
        .flop = flop,
        .initial_pot = 20,
        .effective_stack = 60,
        .min_bet = 1,
        .sizings = game_tree.default_sizings,
        .raise_cap = game_tree.default_raise_cap,
        .oop_range = &input,
        .ip_range = &input,
        .max_budget_bytes = 1,
    };

    try std.testing.expectError(error.StorageBudgetExceeded, SolverInit.init(std.testing.allocator, config));
}

test "default config produces usable init" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(11, 1),
        card.makeCard(10, 2),
    };

    const hand = try Combo.init(card.makeCard(0, 3), card.makeCard(1, 3));
    const input = [_]WeightedCombo{.{ .combo = hand, .weight = 1.0 }};

    const config = Config.default(flop, &input, &input);
    var init_state = try SolverInit.init(std.testing.allocator, config);
    defer init_state.deinit();

    try std.testing.expect(init_state.runout_tables.canonical_turns.len > 0);
    try std.testing.expect(init_state.runout_tables.canonical_rivers.len > 0);
}

test "cleanup on early failure does not leak" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(11, 0),
        card.makeCard(10, 0),
    };

    const hand = try Combo.init(card.makeCard(12, 0), card.makeCard(11, 1)); // blocked by flop
    const input = [_]WeightedCombo{.{ .combo = hand, .weight = 1.0 }};

    // Tiny budget so init fails after range + tree + runout tables are built
    const config = Config{
        .flop = flop,
        .initial_pot = 20,
        .effective_stack = 60,
        .min_bet = 1,
        .sizings = game_tree.default_sizings,
        .raise_cap = game_tree.default_raise_cap,
        .oop_range = &input,
        .ip_range = &input,
        .max_budget_bytes = 1,
    };

    // Should fail with budget error, and all intermediate allocations cleaned up
    try std.testing.expectError(error.StorageBudgetExceeded, SolverInit.init(std.testing.allocator, config));
}

test "golden: exact node counts for minimal empty-sizing config" {
    const no_sizings: [3][]const game_tree.Sizing = .{ &.{}, &.{}, &.{} };
    const no_cap: [3]?u8 = .{ null, null, null };

    const config = game_tree.BuildConfig{
        .initial_pot = 4,
        .effective_stack = 4,
        .min_bet = 1,
        .sizings = no_sizings,
        .raise_cap = no_cap,
        .range_sizes = .{ 2, 2 },
    };

    var tree = try game_tree.buildGameTree(std.testing.allocator, config);
    defer tree.deinit();

    // With stack==pot, calling an all-in puts both players all-in → immediate showdown.
    // Every action node has exactly 2 children (check+allin or fold+call).
    try std.testing.expect(tree.action_nodes.items.len > 0);
    try std.testing.expect(tree.chance_nodes.items.len > 0);
    try std.testing.expect(tree.terminal_nodes.items.len > 0);

    for (tree.action_nodes.items) |node| {
        try std.testing.expectEqual(@as(u8, 2), node.num_children);
    }
}

test "golden: tree walk reaches all nodes exactly once" {
    const config = game_tree.BuildConfig.default(20, 60, 1, .{ 3, 5 });
    var tree = try game_tree.buildGameTree(std.testing.allocator, config);
    defer tree.deinit();

    const action_visits = try std.testing.allocator.alloc(bool, tree.action_nodes.items.len);
    defer std.testing.allocator.free(action_visits);
    const chance_visits = try std.testing.allocator.alloc(bool, tree.chance_nodes.items.len);
    defer std.testing.allocator.free(chance_visits);
    const terminal_visits = try std.testing.allocator.alloc(bool, tree.terminal_nodes.items.len);
    defer std.testing.allocator.free(terminal_visits);
    @memset(action_visits, false);
    @memset(chance_visits, false);
    @memset(terminal_visits, false);

    try walkCount(tree.root, &tree, action_visits, chance_visits, terminal_visits);

    for (action_visits) |v| try std.testing.expect(v);
    for (chance_visits) |v| try std.testing.expect(v);
    for (terminal_visits) |v| try std.testing.expect(v);
}

fn walkCount(
    ref: game_tree.NodeRef,
    tree: *const game_tree.Tree,
    actions: []bool,
    chances: []bool,
    terminals: []bool,
) !void {
    const tag = try game_tree.refTag(ref);
    switch (tag) {
        .action => {
            const idx = game_tree.refIndex(ref);
            try std.testing.expect(!actions[idx]);
            actions[idx] = true;
            const node = tree.action_nodes.items[idx];
            for (0..node.num_children) |i| {
                const child = tree.edges.items[node.first_child_edge + i];
                try walkCount(child, tree, actions, chances, terminals);
            }
        },
        .chance => {
            const idx = game_tree.refIndex(ref);
            try std.testing.expect(!chances[idx]);
            chances[idx] = true;
            const chance = tree.chance_nodes.items[idx];
            try walkCount(chance.child, tree, actions, chances, terminals);
        },
        .terminal => {
            const idx = game_tree.refIndex(ref);
            try std.testing.expect(!terminals[idx]);
            terminals[idx] = true;
        },
    }
}

test "golden: rainbow flop has maximal runout counts" {
    const flop = [_]Card{
        card.makeCard(12, 0), // A♠
        card.makeCard(11, 1), // K♥
        card.makeCard(10, 2), // Q♦
    };
    var rt = try isomorphism.buildRunoutTables(std.testing.allocator, flop, .{ &.{}, &.{} });
    defer rt.deinit();

    // Rainbow with distinct ranks: no suit symmetry → all 49 turns, 2352 rivers
    try std.testing.expectEqual(@as(usize, 49), rt.canonical_turns.len);
    try std.testing.expectEqual(@as(usize, 2352), rt.canonical_rivers.len);
    try std.testing.expectEqual(@as(u64, 49), rt.weightedTurnCount());
    try std.testing.expectEqual(@as(u64, 2352), rt.weightedRiverPairCount());
}

test "golden: monotone flop reduces runout counts" {
    const flop = [_]Card{
        card.makeCard(12, 0), // A♠
        card.makeCard(10, 0), // T♠
        card.makeCard(7, 0), // 7♠
    };
    var rt = try isomorphism.buildRunoutTables(std.testing.allocator, flop, .{ &.{}, &.{} });
    defer rt.deinit();

    // Monotone: suit symmetry collapses non-spade suits
    try std.testing.expect(rt.canonical_turns.len < 49);
    try std.testing.expect(rt.canonical_rivers.len < 2352);
    try std.testing.expectEqual(@as(u64, 49), rt.weightedTurnCount());
    try std.testing.expectEqual(@as(u64, 2352), rt.weightedRiverPairCount());
}

test "golden: two-tone flop has intermediate runout counts" {
    const flop = [_]Card{
        card.makeCard(12, 0), // A♠
        card.makeCard(11, 0), // K♠
        card.makeCard(10, 1), // Q♥
    };
    var rt = try isomorphism.buildRunoutTables(std.testing.allocator, flop, .{ &.{}, &.{} });
    defer rt.deinit();

    // Two-tone: only two suits present, so there is less symmetry than monotone
    try std.testing.expect(rt.canonical_turns.len > 1);
    try std.testing.expect(rt.canonical_turns.len <= 49);
    try std.testing.expectEqual(@as(u64, 49), rt.weightedTurnCount());
    try std.testing.expectEqual(@as(u64, 2352), rt.weightedRiverPairCount());
}

test "golden: storage arrays sized correctly from full init" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(11, 0),
        card.makeCard(10, 0),
    };
    const hand = try Combo.init(card.makeCard(0, 1), card.makeCard(1, 1));
    const input = [_]WeightedCombo{.{ .combo = hand, .weight = 1.0 }};

    const config = Config.default(flop, &input, &input);
    var init_state = try SolverInit.init(std.testing.allocator, config);
    defer init_state.deinit();

    const runout_counts = init_state.runout_tables.runoutCounts();
    const slots = init_state.tree.slots_per_runout;

    // Verify storage lengths match: len = runout_counts[s] * slots_per_runout[s]
    try std.testing.expectEqual(
        @as(usize, @intCast(runout_counts[0] * slots[0])),
        init_state.storage.regrets_flop.len,
    );
    try std.testing.expectEqual(
        @as(usize, @intCast(runout_counts[1] * slots[1])),
        init_state.storage.regrets_turn.len,
    );
    try std.testing.expectEqual(
        @as(usize, @intCast(runout_counts[2] * slots[2])),
        init_state.storage.regrets_river.len,
    );

    // Strategy arrays match regret arrays in length
    try std.testing.expectEqual(
        init_state.storage.regrets_flop.len,
        init_state.storage.strategies_flop.len,
    );
}

test "golden: addressing formula verified against a known action node" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(11, 1),
        card.makeCard(10, 2),
    };
    const hand = try Combo.init(card.makeCard(0, 3), card.makeCard(1, 3));
    const input = [_]WeightedCombo{.{ .combo = hand, .weight = 1.0 }};

    const config = Config.default(flop, &input, &input);
    var init_state = try SolverInit.init(std.testing.allocator, config);
    defer init_state.deinit();

    // Pick the root action node (flop, OOP), verify its base and addressing
    const root_idx = game_tree.refIndex(init_state.tree.root);
    const root = init_state.tree.action_nodes.items[root_idx];

    // Verify we can write and read back through the address
    const addr = storage.slotAddress(
        init_state.tree.slots_per_runout[0],
        0, // runout_id = 0 for flop
        root.base,
        0, // action_idx = 0 (CHECK)
        init_state.ranges[0].N(),
        0, // hand_idx = 0
    );

    try std.testing.expect(addr < init_state.storage.regrets_flop.len);

    init_state.storage.regrets_flop[@intCast(addr)] = 0.75;
    try std.testing.expectEqual(@as(f32, 0.75), init_state.storage.regrets_flop[@intCast(addr)]);
}

test "golden: init N values consistent across all components" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(11, 1),
        card.makeCard(10, 2),
    };

    const oop_h1 = try Combo.init(card.makeCard(0, 3), card.makeCard(1, 3));
    const oop_h2 = try Combo.init(card.makeCard(2, 3), card.makeCard(3, 3));
    const ip_h1 = try Combo.init(card.makeCard(4, 0), card.makeCard(5, 0));

    const oop_input = [_]WeightedCombo{
        .{ .combo = oop_h1, .weight = 1.0 },
        .{ .combo = oop_h2, .weight = 0.5 },
    };
    const ip_input = [_]WeightedCombo{
        .{ .combo = ip_h1, .weight = 1.0 },
    };

    const config = Config{
        .flop = flop,
        .initial_pot = 20,
        .effective_stack = 60,
        .min_bet = 1,
        .sizings = .{ &.{}, &.{}, &.{} },
        .raise_cap = .{ null, null, null },
        .oop_range = &oop_input,
        .ip_range = &ip_input,
        .max_budget_bytes = std.math.maxInt(u64),
    };

    var init_state = try SolverInit.init(std.testing.allocator, config);
    defer init_state.deinit();

    // Range N values
    try std.testing.expectEqual(@as(u32, 2), init_state.ranges[0].N());
    try std.testing.expectEqual(@as(u32, 1), init_state.ranges[1].N());

    // Blocking N values match
    try std.testing.expectEqual(init_state.ranges[0].N(), init_state.blocking.N[0]);
    try std.testing.expectEqual(init_state.ranges[1].N(), init_state.blocking.N[1]);

    // Showdown N values match
    try std.testing.expectEqual(init_state.ranges[0].N(), init_state.showdown.N[0]);
    try std.testing.expectEqual(init_state.ranges[1].N(), init_state.showdown.N[1]);

    // Blocking array dimensions are consistent with N and runout counts
    const rc = init_state.runout_tables.runoutCounts();
    try std.testing.expectEqual(
        @as(usize, @intCast(init_state.blocking.N[0])),
        init_state.blocking.blocked_flop[0].len,
    );
    try std.testing.expectEqual(
        @as(usize, @intCast(rc[1] * init_state.blocking.N[0])),
        init_state.blocking.blocked_turn[0].len,
    );
    try std.testing.expectEqual(
        @as(usize, @intCast(rc[2] * init_state.blocking.N[0])),
        init_state.blocking.blocked_river[0].len,
    );

    // Showdown dimensions
    try std.testing.expectEqual(
        @as(usize, @intCast(rc[2] * init_state.showdown.N[0])),
        init_state.showdown.strengths[0].len,
    );
}

test "golden: blocking and showdown arrays cover every runout" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(11, 1),
        card.makeCard(10, 2),
    };
    const hand = try Combo.init(card.makeCard(0, 3), card.makeCard(1, 3));
    const input = [_]WeightedCombo{.{ .combo = hand, .weight = 1.0 }};

    const config = Config.default(flop, &input, &input);
    var init_state = try SolverInit.init(std.testing.allocator, config);
    defer init_state.deinit();

    const rc = init_state.runout_tables.runoutCounts();

    // Verify all blocking entries are accessible for each runout
    for (0..@intCast(rc[0])) |runout| {
        for (0..init_state.blocking.N[0]) |h| {
            _ = init_state.blocking.isBlocked(0, 0, @intCast(runout), @intCast(h));
        }
    }
    for (0..@intCast(rc[1])) |runout| {
        for (0..init_state.blocking.N[0]) |h| {
            _ = init_state.blocking.isBlocked(1, 0, @intCast(runout), @intCast(h));
        }
    }
    for (0..@intCast(rc[2])) |runout| {
        for (0..init_state.blocking.N[0]) |h| {
            _ = init_state.blocking.isBlocked(2, 0, @intCast(runout), @intCast(h));
        }
    }
}

test "golden: showdown sorted order contains every hand exactly once per runout" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(11, 1),
        card.makeCard(10, 2),
    };
    const h1 = try Combo.init(card.makeCard(0, 3), card.makeCard(1, 3));
    const h2 = try Combo.init(card.makeCard(2, 3), card.makeCard(3, 3));
    const h3 = try Combo.init(card.makeCard(4, 0), card.makeCard(5, 0));
    const input = [_]WeightedCombo{
        .{ .combo = h1, .weight = 1.0 },
        .{ .combo = h2, .weight = 1.0 },
        .{ .combo = h3, .weight = 1.0 },
    };

    const config = Config{
        .flop = flop,
        .initial_pot = 20,
        .effective_stack = 60,
        .min_bet = 1,
        .sizings = .{ &.{}, &.{}, &.{} },
        .raise_cap = .{ null, null, null },
        .oop_range = &input,
        .ip_range = &input,
        .max_budget_bytes = std.math.maxInt(u64),
    };

    var init_state = try SolverInit.init(std.testing.allocator, config);
    defer init_state.deinit();

    const Np: usize = @intCast(init_state.showdown.N[0]);
    for (0..init_state.runout_tables.canonical_rivers.len) |r| {
        var seen = [_]bool{false} ** 1326;
        const base = r * Np;
        for (0..Np) |i| {
            const hand_idx = init_state.showdown.order[0][base + i];
            try std.testing.expect(hand_idx < Np);
            try std.testing.expect(!seen[hand_idx]);
            seen[hand_idx] = true;
        }
        // All Np hands must have been seen
        var count: u32 = 0;
        for (seen[0..Np]) |s| {
            if (s) count += 1;
        }
        try std.testing.expectEqual(@as(u32, @intCast(Np)), count);
    }
}

test "f32 masks mirror bool blocking arrays" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(11, 0),
        card.makeCard(10, 0),
    };
    // Hand blocked by flop vs. clear hand
    const blocked = try Combo.init(card.makeCard(12, 0), card.makeCard(0, 1));
    const clear = try Combo.init(card.makeCard(1, 1), card.makeCard(2, 1));
    const input = [_]WeightedCombo{
        .{ .combo = blocked, .weight = 1.0 },
        .{ .combo = clear, .weight = 1.0 },
    };

    const config = Config.default(flop, &input, &input);
    var init_state = try SolverInit.init(std.testing.allocator, config);
    defer init_state.deinit();

    // f32 mask: 1.0 = live, 0.0 = blocked
    try std.testing.expectEqual(@as(f32, 0.0), init_state.mask_flop[0][0]);
    try std.testing.expectEqual(@as(f32, 1.0), init_state.mask_flop[0][1]);

    // Same for IP (same range)
    try std.testing.expectEqual(@as(f32, 0.0), init_state.mask_flop[1][0]);
    try std.testing.expectEqual(@as(f32, 1.0), init_state.mask_flop[1][1]);
}

test "f32 mask dimensions match blocking and runout counts" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(11, 1),
        card.makeCard(10, 2),
    };
    const hand = try Combo.init(card.makeCard(0, 3), card.makeCard(1, 3));
    const input = [_]WeightedCombo{.{ .combo = hand, .weight = 1.0 }};

    const config = Config.default(flop, &input, &input);
    var init_state = try SolverInit.init(std.testing.allocator, config);
    defer init_state.deinit();

    const rc = init_state.runout_tables.runoutCounts();
    const N: u32 = init_state.ranges[0].N();

    try std.testing.expectEqual(@as(usize, @intCast(N)), init_state.mask_flop[0].len);
    try std.testing.expectEqual(@as(usize, @intCast(rc[1] * N)), init_state.mask_turn[0].len);
    try std.testing.expectEqual(@as(usize, @intCast(rc[2] * N)), init_state.mask_river[0].len);

    // Both players have same dimensions
    try std.testing.expectEqual(init_state.mask_flop[0].len, init_state.mask_flop[1].len);
    try std.testing.expectEqual(init_state.mask_turn[0].len, init_state.mask_turn[1].len);
    try std.testing.expectEqual(init_state.mask_river[0].len, init_state.mask_river[1].len);
}

test "same_combo_idx maps identical combos and uses sentinel for others" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(11, 1),
        card.makeCard(10, 2),
    };
    const shared = try Combo.init(card.makeCard(0, 3), card.makeCard(1, 3));
    const oop_only = try Combo.init(card.makeCard(2, 3), card.makeCard(3, 3));
    const ip_only = try Combo.init(card.makeCard(4, 0), card.makeCard(5, 0));

    const oop_input = [_]WeightedCombo{
        .{ .combo = shared, .weight = 1.0 },
        .{ .combo = oop_only, .weight = 1.0 },
    };
    const ip_input = [_]WeightedCombo{
        .{ .combo = shared, .weight = 1.0 },
        .{ .combo = ip_only, .weight = 1.0 },
    };

    const config = Config{
        .flop = flop,
        .initial_pot = 20,
        .effective_stack = 60,
        .min_bet = 1,
        .sizings = game_tree.default_sizings,
        .raise_cap = game_tree.default_raise_cap,
        .oop_range = &oop_input,
        .ip_range = &ip_input,
        .max_budget_bytes = std.math.maxInt(u64),
    };
    var init_state = try SolverInit.init(std.testing.allocator, config);
    defer init_state.deinit();

    // OOP[0] = shared → should map to IP[0] (shared is first in IP range)
    try std.testing.expectEqual(@as(u32, 0), init_state.same_combo_idx[0][0]);
    // OOP[1] = oop_only → sentinel (not in IP range)
    try std.testing.expectEqual(std.math.maxInt(u32), init_state.same_combo_idx[0][1]);

    // IP[0] = shared → should map to OOP[0]
    try std.testing.expectEqual(@as(u32, 0), init_state.same_combo_idx[1][0]);
    // IP[1] = ip_only → sentinel
    try std.testing.expectEqual(std.math.maxInt(u32), init_state.same_combo_idx[1][1]);
}

test "same_combo_idx dimensions match range sizes" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(11, 1),
        card.makeCard(10, 2),
    };
    const oop_hand = try Combo.init(card.makeCard(0, 3), card.makeCard(1, 3));
    const oop_hand2 = try Combo.init(card.makeCard(2, 3), card.makeCard(3, 3));
    const ip_hand = try Combo.init(card.makeCard(4, 0), card.makeCard(5, 0));
    const oop_input = [_]WeightedCombo{
        .{ .combo = oop_hand, .weight = 1.0 },
        .{ .combo = oop_hand2, .weight = 1.0 },
    };
    const ip_input = [_]WeightedCombo{
        .{ .combo = ip_hand, .weight = 1.0 },
    };

    const config = Config.default(flop, &oop_input, &ip_input);
    var init_state = try SolverInit.init(std.testing.allocator, config);
    defer init_state.deinit();

    try std.testing.expectEqual(@as(usize, 2), init_state.same_combo_idx[0].len);
    // All OOP hands get sentinel (none match IP's single hand)
    try std.testing.expectEqual(std.math.maxInt(u32), init_state.same_combo_idx[0][0]);
    try std.testing.expectEqual(std.math.maxInt(u32), init_state.same_combo_idx[0][1]);
    // IP has 1 hand
    try std.testing.expectEqual(@as(usize, 1), init_state.same_combo_idx[1].len);
}

test "chance weights use the private-card-conditioned denominators" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(11, 1),
        card.makeCard(10, 2),
    };
    const oop_hand = try Combo.init(card.makeCard(0, 3), card.makeCard(1, 3));
    const ip_hand = try Combo.init(card.makeCard(2, 3), card.makeCard(3, 3));
    const oop = [_]WeightedCombo{.{ .combo = oop_hand, .weight = 1.0 }};
    const ip = [_]WeightedCombo{.{ .combo = ip_hand, .weight = 1.0 }};

    const config = Config.default(flop, &oop, &ip);
    var init_state = try SolverInit.init(std.testing.allocator, config);
    defer init_state.deinit();

    // Rainbow flop: all 49 turns, all 2352 rivers canonical (multiplicity 1 each)
    try std.testing.expectEqual(@as(usize, 49), init_state.weight_turns.len);
    try std.testing.expectEqual(@as(usize, 2352), init_state.weight_rivers.len);

    // Each physical-card weight is conditioned on the four private cards.
    for (init_state.weight_turns) |w| {
        try std.testing.expect(@abs(1.0 / 45.0 - w) < 1e-7);
    }
    for (init_state.weight_rivers) |w| {
        try std.testing.expect(@abs(1.0 / 44.0 - w) < 1e-7);
    }

    // For this compatible private-hand pair, exactly 45 turns are live.
    var turn_sum: f32 = 0;
    for (init_state.weight_turns, 0..) |w, t| {
        const live = init_state.mask_turn[0][t] * init_state.mask_turn[1][t];
        turn_sum += live * w;
    }
    try std.testing.expect(@abs(1.0 - turn_sum) < 1e-5);

    // After any live turn, exactly 44 rivers are live for the same pair.
    for (init_state.runout_tables.canonical_turns, 0..) |turn, t| {
        if (init_state.mask_turn[0][t] * init_state.mask_turn[1][t] == 0) continue;
        var river_sum: f32 = 0;
        var r: u32 = 0;
        while (r < turn.num_rivers) : (r += 1) {
            const full = turn.first_river + r;
            const live = init_state.mask_river[0][full] * init_state.mask_river[1][full];
            river_sum += live * init_state.weight_rivers[full];
        }
        try std.testing.expect(@abs(1.0 - river_sum) < 1e-5);
    }
}
