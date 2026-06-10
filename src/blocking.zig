const std = @import("std");
const card = @import("card.zig");
const isomorphism = @import("isomorphism.zig");

const Allocator = std.mem.Allocator;
const Card = card.Card;
const Combo = card.Combo;
const RunoutTables = isomorphism.RunoutTables;

/// Precomputed blocked-hand masks for each canonical runout.
///
/// For each player and each runout, a dense bool array indicates
/// which range-local hands share at least one card with the board.
/// Blocked hands keep their slot in the regret/strategy layout;
/// the CFR kernel skips them via this table.
pub const BlockingTables = struct {
    allocator: Allocator,
    N: [2]u32,

    /// blocked_flop[p][hand_idx] — 1 runout per street.
    blocked_flop: [2][]bool,
    /// blocked_turn[p][turn_runout * N_p + hand_idx]
    blocked_turn: [2][]bool,
    /// blocked_river[p][river_runout * N_p + hand_idx]
    blocked_river: [2][]bool,

    pub fn init(
        allocator: Allocator,
        hands: [2][]const Combo,
        flop: [3]Card,
        runout_tables: *const RunoutTables,
    ) !BlockingTables {
        const N: [2]u32 = .{
            @intCast(hands[0].len),
            @intCast(hands[1].len),
        };
        const N0: usize = hands[0].len;
        const N1: usize = hands[1].len;
        const T_count = runout_tables.canonical_turns.len;
        const R_count = runout_tables.canonical_rivers.len;

        const bf0 = try allocator.alloc(bool, N0);
        errdefer allocator.free(bf0);
        const bf1 = try allocator.alloc(bool, N1);
        errdefer allocator.free(bf1);

        const bt0 = try allocator.alloc(bool, T_count * N0);
        errdefer allocator.free(bt0);
        const bt1 = try allocator.alloc(bool, T_count * N1);
        errdefer allocator.free(bt1);

        const br0 = try allocator.alloc(bool, R_count * N0);
        errdefer allocator.free(br0);
        const br1 = try allocator.alloc(bool, R_count * N1);
        errdefer allocator.free(br1);

        const flop_mask = card.boardMask(flop[0..]);

        fillBlocked(bf0, hands[0], flop_mask);
        fillBlocked(bf1, hands[1], flop_mask);

        for (runout_tables.canonical_turns, 0..) |turn, t| {
            const turn_mask = card.boardMask(&.{turn.card});
            const dead_mask = flop_mask | turn_mask;
            const t_off0 = t * N0;
            const t_off1 = t * N1;
            fillBlocked(bt0[t_off0..][0..N0], hands[0], dead_mask);
            fillBlocked(bt1[t_off1..][0..N1], hands[1], dead_mask);
        }

        for (runout_tables.canonical_turns, 0..) |turn, t| {
            const turn_mask = card.boardMask(&.{turn.card});
            const rivers = runout_tables.riversForTurn(t);
            for (rivers, 0..) |river, r| {
                // Must include the flop: a hand sharing any board card (flop,
                // turn, or river) is blocked. Omitting the flop here would mark
                // flop-blocked hands as live, leaking garbage CFVs through the
                // river return-side mask (CFR spec §3.3).
                const river_mask = flop_mask | turn_mask | card.mask(river.card);
                const river_flat_index: usize = @intCast(turn.first_river);
                const r_off0 = (river_flat_index + r) * N0;
                const r_off1 = (river_flat_index + r) * N1;
                fillBlocked(br0[r_off0..][0..N0], hands[0], river_mask);
                fillBlocked(br1[r_off1..][0..N1], hands[1], river_mask);
            }
        }

        return .{
            .allocator = allocator,
            .N = N,
            .blocked_flop = .{ bf0, bf1 },
            .blocked_turn = .{ bt0, bt1 },
            .blocked_river = .{ br0, br1 },
        };
    }

    pub fn deinit(self: *BlockingTables) void {
        self.allocator.free(self.blocked_flop[0]);
        self.allocator.free(self.blocked_flop[1]);
        self.allocator.free(self.blocked_turn[0]);
        self.allocator.free(self.blocked_turn[1]);
        self.allocator.free(self.blocked_river[0]);
        self.allocator.free(self.blocked_river[1]);
        self.* = undefined;
    }

    /// True if the given hand is blocked for this runout (shares a card with the board).
    pub fn isBlocked(
        self: BlockingTables,
        street: u8,
        player: u8,
        runout_id: u32,
        hand_idx: u32,
    ) bool {
        const p: usize = player;
        const Np: usize = @intCast(self.N[p]);
        const offset = @as(usize, runout_id) * Np + @as(usize, hand_idx);
        return switch (street) {
            0 => self.blocked_flop[p][offset],
            1 => self.blocked_turn[p][offset],
            2 => self.blocked_river[p][offset],
            else => unreachable,
        };
    }
};

fn fillBlocked(blocked: []bool, hands: []const Combo, board_mask: u64) void {
    for (hands, 0..) |hand, i| {
        blocked[i] = hand.conflictsWithMask(board_mask);
    }
}

test "flop blocks hands that share a card" {
    const flop = [_]Card{
        card.makeCard(12, 0), // A♠
        card.makeCard(11, 0), // K♠
        card.makeCard(10, 0), // Q♠
    };

    const blocked_hand = try Combo.init(card.makeCard(12, 0), card.makeCard(11, 1));
    const clear_hand = try Combo.init(card.makeCard(0, 1), card.makeCard(1, 1));

    const hands: [2][]const Combo = .{
        &.{ blocked_hand, clear_hand },
        &.{},
    };

    var rt = try isomorphism.buildRunoutTables(std.testing.allocator, flop, .{ &.{}, &.{} });
    defer rt.deinit();

    var bt = try BlockingTables.init(std.testing.allocator, hands, flop, &rt);
    defer bt.deinit();

    try std.testing.expect(bt.blocked_flop[0][0]);
    try std.testing.expect(!bt.blocked_flop[0][1]);
}

test "flop with no blocking for disjoint range" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(11, 0),
        card.makeCard(10, 0),
    };

    const hand = try Combo.init(card.makeCard(0, 1), card.makeCard(1, 1));

    const hands: [2][]const Combo = .{
        &.{hand},
        &.{},
    };

    var rt = try isomorphism.buildRunoutTables(std.testing.allocator, flop, .{ &.{}, &.{} });
    defer rt.deinit();

    var bt = try BlockingTables.init(std.testing.allocator, hands, flop, &rt);
    defer bt.deinit();

    try std.testing.expect(!bt.blocked_flop[0][0]);
}

test "empty range produces empty blocked arrays" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(11, 0),
        card.makeCard(10, 0),
    };

    const hands: [2][]const Combo = .{ &.{}, &.{} };

    var rt = try isomorphism.buildRunoutTables(std.testing.allocator, flop, .{ &.{}, &.{} });
    defer rt.deinit();

    var bt = try BlockingTables.init(std.testing.allocator, hands, flop, &rt);
    defer bt.deinit();

    try std.testing.expectEqual(@as(u32, 0), bt.N[0]);
    try std.testing.expectEqual(@as(usize, 0), bt.blocked_flop[0].len);
    try std.testing.expectEqual(@as(usize, 0), bt.blocked_turn[0].len);
    try std.testing.expectEqual(@as(usize, 0), bt.blocked_river[0].len);
}

test "turn blocking adds turn card to dead cards" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(11, 0),
        card.makeCard(10, 0),
    };

    // Hand that shares with flop: blocked on flop and turn
    const flop_blocked = try Combo.init(card.makeCard(12, 0), card.makeCard(0, 1));
    // Hand that shares only with turn card (2♠): NOT blocked on flop, blocked on turn where 2♠ appears
    const turn_blocked = try Combo.init(card.makeCard(0, 0), card.makeCard(1, 2));
    // Hand clear of both: never blocked
    const clear = try Combo.init(card.makeCard(1, 1), card.makeCard(2, 1));

    const hands: [2][]const Combo = .{
        &.{ flop_blocked, turn_blocked, clear },
        &.{},
    };

    var rt = try isomorphism.buildRunoutTables(std.testing.allocator, flop, .{ &.{}, &.{} });
    defer rt.deinit();

    var bt = try BlockingTables.init(std.testing.allocator, hands, flop, &rt);
    defer bt.deinit();

    // flop_blocked should be blocked on flop
    try std.testing.expect(bt.blocked_flop[0][0]);
    // turn_blocked should NOT be blocked on flop (it doesn't share flop cards)
    try std.testing.expect(!bt.blocked_flop[0][1]);
    // clear should not be blocked on flop
    try std.testing.expect(!bt.blocked_flop[0][2]);

    // Find the first canonical turn that is 2♠ (index 0, suit 0)
    // In a rainbow flop with no symmetry, the canonical turns are all 49 cards
    // 2♠ should be one of them. Find its index.
    const two_spades = card.makeCard(0, 0);
    var two_spades_turn_idx: ?usize = null;
    for (rt.canonical_turns, 0..) |turn, t| {
        if (card.index(turn.card) == card.index(two_spades)) {
            two_spades_turn_idx = t;
            break;
        }
    }
    try std.testing.expect(two_spades_turn_idx != null);
    const t_idx = two_spades_turn_idx.?;

    // flop_blocked still blocked because turn adds 2♠ but flop is already blocking it
    try std.testing.expect(bt.blocked_turn[0][t_idx * 3 + 0]);
    // turn_blocked should now be blocked (its 2♠ is on the board)
    try std.testing.expect(bt.blocked_turn[0][t_idx * 3 + 1]);
    // clear remains clear
    try std.testing.expect(!bt.blocked_turn[0][t_idx * 3 + 2]);
}

test "river blocking compounds flop + turn + river" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(11, 0),
        card.makeCard(10, 0),
    };

    const always_blocked = try Combo.init(card.makeCard(12, 0), card.makeCard(0, 1));
    const river_blocked = try Combo.init(card.makeCard(0, 0), card.makeCard(1, 2));
    const clear = try Combo.init(card.makeCard(1, 1), card.makeCard(2, 1));

    const hands: [2][]const Combo = .{
        &.{ always_blocked, river_blocked, clear },
        &.{},
    };

    var rt = try isomorphism.buildRunoutTables(std.testing.allocator, flop, .{ &.{}, &.{} });
    defer rt.deinit();

    var bt = try BlockingTables.init(std.testing.allocator, hands, flop, &rt);
    defer bt.deinit();

    // Ground truth: a hand is blocked on a river runout iff it shares a card
    // with the FULL canonical board (flop ∪ turn ∪ river). Recompute that
    // independently for every runout and every hand. This catches a river_mask
    // that forgets the flop (always_blocked shares A♠ with the flop, so it must
    // be blocked on every single runout).
    const flop_mask = card.boardMask(flop[0..]);
    const test_hands = [_]Combo{ always_blocked, river_blocked, clear };
    var saw_always_blocked = false;
    for (rt.canonical_turns, 0..) |turn, t| {
        for (rt.riversForTurn(t), 0..) |river, r| {
            const idx: usize = @intCast(turn.first_river);
            const base = (idx + r) * 3;
            const board_mask = flop_mask | card.mask(turn.card) | card.mask(river.card);
            for (test_hands, 0..) |hand, h| {
                try std.testing.expectEqual(
                    hand.conflictsWithMask(board_mask),
                    bt.blocked_river[0][base + h],
                );
            }
            try std.testing.expect(bt.blocked_river[0][base + 0]); // always flop-blocked
            saw_always_blocked = true;
        }
    }
    try std.testing.expect(saw_always_blocked);
}

test "both players blocked independently" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(11, 0),
        card.makeCard(10, 0),
    };

    const oop_blocked = try Combo.init(card.makeCard(12, 0), card.makeCard(0, 1));
    const oop_clear = try Combo.init(card.makeCard(1, 1), card.makeCard(2, 1));
    const ip_blocked = try Combo.init(card.makeCard(11, 0), card.makeCard(0, 2));
    const ip_clear = try Combo.init(card.makeCard(3, 1), card.makeCard(4, 1));

    const hands: [2][]const Combo = .{
        &.{ oop_blocked, oop_clear },
        &.{ ip_blocked, ip_clear },
    };

    var rt = try isomorphism.buildRunoutTables(std.testing.allocator, flop, .{ &.{}, &.{} });
    defer rt.deinit();

    var bt = try BlockingTables.init(std.testing.allocator, hands, flop, &rt);
    defer bt.deinit();

    try std.testing.expect(bt.blocked_flop[0][0]);
    try std.testing.expect(!bt.blocked_flop[0][1]);
    try std.testing.expect(bt.blocked_flop[1][0]);
    try std.testing.expect(!bt.blocked_flop[1][1]);
}

test "isBlocked convenience function" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(11, 0),
        card.makeCard(10, 0),
    };

    const blocked_hand = try Combo.init(card.makeCard(12, 0), card.makeCard(0, 1));
    const clear_hand = try Combo.init(card.makeCard(1, 1), card.makeCard(2, 1));

    const hands: [2][]const Combo = .{
        &.{ blocked_hand, clear_hand },
        &.{},
    };

    var rt = try isomorphism.buildRunoutTables(std.testing.allocator, flop, .{ &.{}, &.{} });
    defer rt.deinit();

    var bt = try BlockingTables.init(std.testing.allocator, hands, flop, &rt);
    defer bt.deinit();

    try std.testing.expect(bt.isBlocked(0, 0, 0, 0));
    try std.testing.expect(!bt.isBlocked(0, 0, 0, 1));
}

test "turn and river counts match runout table dimensions" {
    const flop = [_]Card{
        card.makeCard(12, 0),
        card.makeCard(11, 0),
        card.makeCard(10, 0),
    };

    const hand = try Combo.init(card.makeCard(0, 1), card.makeCard(1, 1));
    const hands: [2][]const Combo = .{ &.{hand}, &.{} };

    var rt = try isomorphism.buildRunoutTables(std.testing.allocator, flop, .{ &.{}, &.{} });
    defer rt.deinit();

    var bt = try BlockingTables.init(std.testing.allocator, hands, flop, &rt);
    defer bt.deinit();

    try std.testing.expectEqual(rt.canonical_turns.len, bt.blocked_turn[0].len);
    try std.testing.expectEqual(rt.canonical_rivers.len, bt.blocked_river[0].len);
}
