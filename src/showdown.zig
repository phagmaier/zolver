const std = @import("std");
const card = @import("card.zig");
const evaluator_mod = @import("evaluator.zig");
const isomorphism = @import("isomorphism.zig");

const Allocator = std.mem.Allocator;
const Card = card.Card;
const Combo = card.Combo;
const RunoutTables = isomorphism.RunoutTables;
const Evaluator = evaluator_mod.Evaluator;

/// Precomputed hand-strength and sorted-order tables for every canonical river runout.
///
/// For each player and each runout:
/// - `strengths[p][runout * N_p + hand_idx]` — u32 hand strength (0 for blocked hands)
/// - `order[p][runout * N_p + sorted_idx]`   — hand index sorted by decreasing strength
///
/// Blocked hands are assigned strength 0. The CFR kernel skips them via the
/// blocking table, so their position in the sorted order is irrelevant.
pub const ShowdownTables = struct {
    allocator: Allocator,
    N: [2]u32,

    strengths: [2][]u32,
    order: [2][]u32,

    pub fn init(
        allocator: Allocator,
        hands: [2][]const Combo,
        flop: [3]Card,
        runout_tables: *const RunoutTables,
        evaluator: *const Evaluator,
    ) !ShowdownTables {
        const N: [2]u32 = .{
            @intCast(hands[0].len),
            @intCast(hands[1].len),
        };
        const N0: usize = hands[0].len;
        const N1: usize = hands[1].len;
        const R_count = runout_tables.canonical_rivers.len;

        const strengths_0 = try allocator.alloc(u32, R_count * N0);
        errdefer allocator.free(strengths_0);
        const strengths_1 = try allocator.alloc(u32, R_count * N1);
        errdefer allocator.free(strengths_1);

        const order_0 = try allocator.alloc(u32, R_count * N0);
        errdefer allocator.free(order_0);
        const order_1 = try allocator.alloc(u32, R_count * N1);
        errdefer allocator.free(order_1);

        for (runout_tables.canonical_turns, 0..) |turn, t| {
            const rivers = runout_tables.riversForTurn(t);
            for (rivers, 0..) |river, r| {
                const river_flat_index: usize = @intCast(turn.first_river);
                const full_index = river_flat_index + r;
                const board = [_]Card{ flop[0], flop[1], flop[2], turn.card, river.card };
                const board_mask = card.boardMask(board[0..]);

                const base_0 = full_index * N0;
                const base_1 = full_index * N1;
                computeStrengths(
                    strengths_0[base_0..][0..N0],
                    order_0[base_0..][0..N0],
                    hands[0],
                    board,
                    board_mask,
                    evaluator,
                );
                computeStrengths(
                    strengths_1[base_1..][0..N1],
                    order_1[base_1..][0..N1],
                    hands[1],
                    board,
                    board_mask,
                    evaluator,
                );
            }
        }

        return .{
            .allocator = allocator,
            .N = N,
            .strengths = .{ strengths_0, strengths_1 },
            .order = .{ order_0, order_1 },
        };
    }

    pub fn deinit(self: *ShowdownTables) void {
        self.allocator.free(self.strengths[0]);
        self.allocator.free(self.strengths[1]);
        self.allocator.free(self.order[0]);
        self.allocator.free(self.order[1]);
        self.* = undefined;
    }
};

fn computeStrengths(
    strengths: []u32,
    order: []u32,
    hands: []const Combo,
    board: [5]Card,
    board_mask: u64,
    evaluator: *const Evaluator,
) void {
    for (hands, 0..) |hand, i| {
        if (hand.conflictsWithMask(board_mask)) {
            strengths[i] = 0;
        } else {
            var hand_7 = [_]u32{0} ** 7;
            @memcpy(hand_7[0..5], &board);
            hand_7[5] = hand.first;
            hand_7[6] = hand.second;
            strengths[i] = evaluator.handStrength(hand_7);
        }
    }

    for (order, 0..) |_, i| {
        order[i] = @intCast(i);
    }

    std.mem.sort(u32, order, strengths, orderByStrengthDesc);
}

fn orderByStrengthDesc(strengths: []u32, a: u32, b: u32) bool {
    return strengths[@intCast(a)] > strengths[@intCast(b)];
}

test "strength array dimensions match runout count" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(11, 0),
        card.makeCard(10, 0),
    };
    const hand = try Combo.init(card.makeCard(0, 1), card.makeCard(1, 1));
    const hands: [2][]const Combo = .{ &.{hand}, &.{} };

    var rt = try isomorphism.buildRunoutTables(std.testing.allocator, flop, .{ &.{}, &.{} });
    defer rt.deinit();

    var eval = Evaluator{}; // zero-sized, no init needed
    var st = try ShowdownTables.init(std.testing.allocator, hands, flop, &rt, &eval);
    defer st.deinit();

    try std.testing.expectEqual(@as(usize, rt.canonical_rivers.len), st.strengths[0].len);
    try std.testing.expectEqual(@as(usize, rt.canonical_rivers.len), st.order[0].len);
    try std.testing.expectEqual(@as(u32, 1), st.N[0]);
}

test "blocked hand gets strength zero on every runout" {
    const flop = [_]Card{
        card.makeCard(12, 0), // A♠
        card.makeCard(11, 0), // K♠
        card.makeCard(10, 0), // Q♠
    };
    const hand = try Combo.init(card.makeCard(12, 0), card.makeCard(0, 1));
    const hands: [2][]const Combo = .{ &.{hand}, &.{} };

    var rt = try isomorphism.buildRunoutTables(std.testing.allocator, flop, .{ &.{}, &.{} });
    defer rt.deinit();

    var eval = Evaluator{};
    var st = try ShowdownTables.init(std.testing.allocator, hands, flop, &rt, &eval);
    defer st.deinit();

    for (st.strengths[0]) |s| {
        try std.testing.expectEqual(@as(u32, 0), s);
    }
}

test "non-blocked hand gets nonzero strength on some runout" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(11, 1),
        card.makeCard(10, 2),
    };
    const hand = try Combo.init(card.makeCard(0, 3), card.makeCard(1, 3));
    const hands: [2][]const Combo = .{ &.{hand}, &.{} };

    var rt = try isomorphism.buildRunoutTables(std.testing.allocator, flop, .{ &.{}, &.{} });
    defer rt.deinit();

    var eval = Evaluator{};
    var st = try ShowdownTables.init(std.testing.allocator, hands, flop, &rt, &eval);
    defer st.deinit();

    // At least one runout should not block this hand
    var found_nonzero = false;
    for (st.strengths[0]) |s| {
        if (s > 0) found_nonzero = true;
    }
    try std.testing.expect(found_nonzero);
}

test "sorted order is non-increasing in strength" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(11, 0),
        card.makeCard(10, 0),
    };
    const flush_draw = try Combo.init(card.makeCard(9, 0), card.makeCard(8, 0));
    const high_card = try Combo.init(card.makeCard(0, 1), card.makeCard(1, 1));
    const hands: [2][]const Combo = .{ &.{ flush_draw, high_card }, &.{} };

    var rt = try isomorphism.buildRunoutTables(std.testing.allocator, flop, .{ &.{}, &.{} });
    defer rt.deinit();

    var eval = Evaluator{};
    var st = try ShowdownTables.init(std.testing.allocator, hands, flop, &rt, &eval);
    defer st.deinit();

    const N_p: usize = 2;
    for (0..rt.canonical_rivers.len) |r| {
        const base = r * N_p;
        const h0 = st.order[0][base];     // hand index of strongest
        const h1 = st.order[0][base + 1]; // hand index of second strongest
        const s0 = st.strengths[0][base + h0];
        const s1 = st.strengths[0][base + h1];
        try std.testing.expect(s0 >= s1);
    }
}

test "stronger hand always ranks higher when both unblocked" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(11, 0),
        card.makeCard(10, 0),
    };
    const strong = try Combo.init(card.makeCard(9, 0), card.makeCard(8, 0));
    const weak = try Combo.init(card.makeCard(0, 1), card.makeCard(1, 1));
    const hands: [2][]const Combo = .{ &.{ strong, weak }, &.{} };

    var rt = try isomorphism.buildRunoutTables(std.testing.allocator, flop, .{ &.{}, &.{} });
    defer rt.deinit();

    var eval = Evaluator{};
    var st = try ShowdownTables.init(std.testing.allocator, hands, flop, &rt, &eval);
    defer st.deinit();

    // On runouts where both hands are unblocked, strong >= weak
    var checked_any = false;
    for (0..rt.canonical_rivers.len) |r| {
        const base = r * 2;
        const s0 = st.strengths[0][base];
        const s1 = st.strengths[0][base + 1];
        if (s0 > 0 and s1 > 0) {
            try std.testing.expect(s0 >= s1);
            checked_any = true;
        }
    }
    try std.testing.expect(checked_any);
}

test "empty range produces empty arrays" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(11, 0),
        card.makeCard(10, 0),
    };
    const hands: [2][]const Combo = .{ &.{}, &.{} };

    var rt = try isomorphism.buildRunoutTables(std.testing.allocator, flop, .{ &.{}, &.{} });
    defer rt.deinit();

    var eval = Evaluator{};
    var st = try ShowdownTables.init(std.testing.allocator, hands, flop, &rt, &eval);
    defer st.deinit();

    try std.testing.expectEqual(@as(u32, 0), st.N[0]);
    try std.testing.expectEqual(@as(usize, 0), st.strengths[0].len);
    try std.testing.expectEqual(@as(usize, 0), st.order[0].len);
}

test "both players evaluated independently" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(11, 0),
        card.makeCard(10, 0),
    };
    const oop_hand = try Combo.init(card.makeCard(9, 0), card.makeCard(8, 0));
    const ip_hand = try Combo.init(card.makeCard(0, 1), card.makeCard(1, 1));
    const hands: [2][]const Combo = .{ &.{oop_hand}, &.{ip_hand} };

    var rt = try isomorphism.buildRunoutTables(std.testing.allocator, flop, .{ &.{}, &.{} });
    defer rt.deinit();

    var eval = Evaluator{};
    var st = try ShowdownTables.init(std.testing.allocator, hands, flop, &rt, &eval);
    defer st.deinit();

    try std.testing.expectEqual(@as(u32, 1), st.N[0]);
    try std.testing.expectEqual(@as(u32, 1), st.N[1]);

    // OOP flush draw should be at least as strong as IP high cards when both unblocked
    var checked_any = false;
    for (0..rt.canonical_rivers.len) |r| {
        const s_oop = st.strengths[0][r];
        const s_ip = st.strengths[1][r];
        if (s_oop > 0 and s_ip > 0) {
            try std.testing.expect(s_oop >= s_ip);
            checked_any = true;
        }
    }
    try std.testing.expect(checked_any);
}

test "monotone flop flush draw vs offsuit" {
    const flop = [_]Card{
        card.makeCard(12, 0), // A♠
        card.makeCard(11, 0), // K♠
        card.makeCard(10, 0), // Q♠
    };
    const suited = try Combo.init(card.makeCard(7, 0), card.makeCard(6, 0));
    const offsuit = try Combo.init(card.makeCard(7, 1), card.makeCard(6, 2));
    const hands: [2][]const Combo = .{ &.{ suited, offsuit }, &.{} };

    var rt = try isomorphism.buildRunoutTables(std.testing.allocator, flop, .{ &.{}, &.{} });
    defer rt.deinit();

    var eval = Evaluator{};
    var st = try ShowdownTables.init(std.testing.allocator, hands, flop, &rt, &eval);
    defer st.deinit();

    // suited flush draw >= offsuit when both are unblocked
    var checked_any = false;
    for (0..rt.canonical_rivers.len) |r| {
        const ss = st.strengths[0][r * 2];
        const os = st.strengths[0][r * 2 + 1];
        if (ss > 0 and os > 0) {
            try std.testing.expect(ss >= os);
            checked_any = true;
        }
    }
    try std.testing.expect(checked_any);
}
