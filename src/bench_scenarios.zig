const std = @import("std");

const card_mod = @import("card.zig");
const range_mod = @import("range.zig");
const gamestate_mod = @import("gamestate.zig");
const cfr = @import("cfr.zig");

const Card = u32;
const Range = range_mod.Range;
const HandTable = range_mod.HandTable;
const Hand = range_mod.Hand;
const NUM_HANDS = cfr.NUM_HANDS;

pub const Built = struct {
    board: [5]Card,
    p1: Range,
    p2: Range,

    pub fn deinit(self: *Built, allocator: std.mem.Allocator) void {
        self.p1.deinit(allocator);
        self.p2.deinit(allocator);
    }
};

pub const Scenario = struct {
    name: []const u8,
    street: gamestate_mod.Street,
    truncate_after: ?gamestate_mod.Street,
    pot: f32,
    stack1: f32,
    stack2: f32,
    iters: usize,
    warmup: usize,
    build: *const fn (std.mem.Allocator) anyerror!Built,
};

pub fn buildPolarizedRiver(allocator: std.mem.Allocator) !Built {
    const ht = HandTable.init();
    const board = [5]Card{
        card_mod.makeCard(12, 0),
        card_mod.makeCard(11, 0),
        card_mod.makeCard(0, 1),
        card_mod.makeCard(1, 2),
        card_mod.makeCard(5, 3),
    };

    var p1 = try Range.initEmpty(allocator, 3);
    p1.active_indices[0] = ht.getIndex(Hand.init(card_mod.makeCard(12, 1), card_mod.makeCard(12, 2))).?;
    p1.active_indices[1] = ht.getIndex(Hand.init(card_mod.makeCard(11, 1), card_mod.makeCard(11, 2))).?;
    p1.active_indices[2] = ht.getIndex(Hand.init(card_mod.makeCard(5, 0), card_mod.makeCard(0, 3))).?;
    p1.probs[0] = 0.2;
    p1.probs[1] = 0.2;
    p1.probs[2] = 0.6;
    p1.normalize();

    var p2 = try Range.initEmpty(allocator, 3);
    p2.active_indices[0] = ht.getIndex(Hand.init(card_mod.makeCard(12, 1), card_mod.makeCard(10, 2))).?;
    p2.active_indices[1] = ht.getIndex(Hand.init(card_mod.makeCard(12, 1), card_mod.makeCard(9, 2))).?;
    p2.active_indices[2] = ht.getIndex(Hand.init(card_mod.makeCard(12, 1), card_mod.makeCard(8, 2))).?;
    p2.probs[0] = 0.33;
    p2.probs[1] = 0.33;
    p2.probs[2] = 0.34;
    p2.normalize();

    return .{ .board = board, .p1 = p1, .p2 = p2 };
}

pub fn buildFullRangeTurn(allocator: std.mem.Allocator) !Built {
    // Dry-ish turn board.
    const board = [5]Card{
        card_mod.makeCard(12, 0),
        card_mod.makeCard(7, 1),
        card_mod.makeCard(2, 2),
        card_mod.makeCard(10, 3),
        0,
    };
    return fullRangeFor(allocator, board);
}

pub fn buildFullRangeFlop(allocator: std.mem.Allocator) !Built {
    const board = [5]Card{
        card_mod.makeCard(12, 0),
        card_mod.makeCard(7, 1),
        card_mod.makeCard(2, 2),
        0,
        0,
    };
    return fullRangeFor(allocator, board);
}

pub fn fullRangeFor(allocator: std.mem.Allocator, board: [5]Card) !Built {
    var p1 = try Range.initEmpty(allocator, NUM_HANDS);
    var p2 = try Range.initEmpty(allocator, NUM_HANDS);
    var i: u16 = 0;
    while (i < NUM_HANDS) : (i += 1) {
        p1.active_indices[i] = i;
        p1.probs[i] = 1.0;
        p2.active_indices[i] = i;
        p2.probs[i] = 1.0;
    }
    p1.normalize();
    p2.normalize();
    return .{ .board = board, .p1 = p1, .p2 = p2 };
}

// Iter counts are tuned so the full bench runs in <30s in ReleaseFast. The
// flop scenario is dominated by allInEquityLeaf's 2,352-runout enumeration;
// 1 iter is plenty to measure iters/s, and we skip warmup there to avoid
// paying the same 15s cost twice.
pub const scenarios = [_]Scenario{
    .{
        .name = "river-polarized",
        .street = .RIVER,
        .truncate_after = null,
        .pot = 100,
        .stack1 = 500,
        .stack2 = 500,
        .iters = 200,
        .warmup = 1,
        .build = buildPolarizedRiver,
    },
    .{
        .name = "turn-fullrange",
        .street = .TURN,
        .truncate_after = null,
        .pot = 50,
        .stack1 = 400,
        .stack2 = 400,
        .iters = 50,
        .warmup = 1,
        .build = buildFullRangeTurn,
    },
    .{
        .name = "flop-fullrange-trunc",
        .street = .FLOP,
        .truncate_after = .FLOP,
        .pot = 20,
        .stack1 = 200,
        .stack2 = 200,
        .iters = 1,
        .warmup = 0,
        .build = buildFullRangeFlop,
    },
    // The user's real-world target: full-range flop, ~100bb effective stack.
    // Larger stack -> more legal bet/raise/all-in branches than the 200-chip
    // variant above. This is the scenario the perf work is gating on.
    .{
        .name = "flop-fullrange-100bb-trunc",
        .street = .FLOP,
        .truncate_after = .FLOP,
        .pot = 10,
        .stack1 = 1000,
        .stack2 = 1000,
        .iters = 1,
        .warmup = 0,
        .build = buildFullRangeFlop,
    },
};
