const std = @import("std");
const game_tree = @import("game_tree.zig");

const Allocator = std.mem.Allocator;
const Street = game_tree.Street;

pub const bytes_per_regret: u64 = @sizeOf(f32); // 4
// Strategy storage holds a globally normalized cumulative average. The solver
// divides the conceptual DCFR sum by t and the CFR+ sum by t², which preserves
// extraction ratios while bounding values. f32 is retained for stable repeated
// updates and SIMD throughput; f16 loses too much precision in long solves.
pub const bytes_per_strategy: u64 = @sizeOf(f32); // 4
pub const bytes_per_slot: u64 = bytes_per_regret + bytes_per_strategy; // 8

/// Compute the total bytes required for regret (f32) + strategy (f32) storage
/// across all three streets.
pub fn memoryEstimate(slots_per_runout: [3]u64, runout_counts: [3]u64) u64 {
    var total: u64 = 0;
    for (slots_per_runout, 0..) |slots, s| {
        total += slots * runout_counts[s] * bytes_per_slot;
    }
    return total;
}

pub const Storage = struct {
    allocator: Allocator,

    regrets_flop: []f32,
    regrets_turn: []f32,
    regrets_river: []f32,

    strategies_flop: []f32,
    strategies_turn: []f32,
    strategies_river: []f32,

    /// Allocate and zero-initialize all regret and strategy arrays.
    /// Returns error.StorageBudgetExceeded if the estimate exceeds max_budget_bytes.
    pub fn init(
        allocator: Allocator,
        slots_per_runout: [3]u64,
        runout_counts: [3]u64,
        max_budget_bytes: u64,
    ) !Storage {
        const budget = memoryEstimate(slots_per_runout, runout_counts);
        if (budget > max_budget_bytes) return error.StorageBudgetExceeded;

        const len0 = slots_per_runout[0] * runout_counts[0];
        const len1 = slots_per_runout[1] * runout_counts[1];
        const len2 = slots_per_runout[2] * runout_counts[2];

        var storage: Storage = undefined;
        storage.allocator = allocator;

        storage.regrets_flop = try allocator.alloc(f32, @intCast(len0));
        errdefer allocator.free(storage.regrets_flop);
        storage.regrets_turn = try allocator.alloc(f32, @intCast(len1));
        errdefer allocator.free(storage.regrets_turn);
        storage.regrets_river = try allocator.alloc(f32, @intCast(len2));
        errdefer allocator.free(storage.regrets_river);

        storage.strategies_flop = try allocator.alloc(f32, @intCast(len0));
        errdefer allocator.free(storage.strategies_flop);
        storage.strategies_turn = try allocator.alloc(f32, @intCast(len1));
        errdefer allocator.free(storage.strategies_turn);
        storage.strategies_river = try allocator.alloc(f32, @intCast(len2));
        errdefer allocator.free(storage.strategies_river);

        @memset(storage.regrets_flop, 0);
        @memset(storage.regrets_turn, 0);
        @memset(storage.regrets_river, 0);
        @memset(storage.strategies_flop, 0);
        @memset(storage.strategies_turn, 0);
        @memset(storage.strategies_river, 0);

        return storage;
    }

    pub fn deinit(self: *Storage) void {
        self.allocator.free(self.regrets_flop);
        self.allocator.free(self.regrets_turn);
        self.allocator.free(self.regrets_river);
        self.allocator.free(self.strategies_flop);
        self.allocator.free(self.strategies_turn);
        self.allocator.free(self.strategies_river);
        self.* = undefined;
    }
};

/// Compute the u64 linear address for a single (runout, node, action, hand) slot.
/// Same address applies to both the regret and strategy arrays of a street
/// since they share identical layout.
///
/// `slots_per_runout` is the value for the target street (not the full array).
///
/// Formula: runout_id * slots_per_runout + node_base + action_idx * N_p + hand_idx
pub inline fn slotAddress(
    slots_per_runout: u64,
    runout_id: u64,
    node_base: u32,
    action_idx: u32,
    N_p: u32,
    hand_idx: u32,
) u64 {
    return runout_id * slots_per_runout +
        @as(u64, node_base) +
        @as(u64, action_idx) * N_p +
        hand_idx;
}

/// Convenience overload that indexes into the per-street array.
pub inline fn streetSlotAddress(
    slots_per_runout: [3]u64,
    street: Street,
    runout_id: u64,
    node_base: u32,
    action_idx: u32,
    N_p: u32,
    hand_idx: u32,
) u64 {
    return slotAddress(
        slots_per_runout[@intFromEnum(street)],
        runout_id,
        node_base,
        action_idx,
        N_p,
        hand_idx,
    );
}

test "memory estimate single street" {
    // 10 slots * 2 runouts * 8 bytes/slot
    const estimate = memoryEstimate(.{ 10, 0, 0 }, .{ 2, 0, 0 });
    try std.testing.expectEqual(@as(u64, 160), estimate);
}

test "memory estimate all streets" {
    const estimate = memoryEstimate(.{ 10, 20, 30 }, .{ 1, 49, 2352 });
    try std.testing.expectEqual(@as(u64, 572400), estimate);
}

test "memory estimate zero slots" {
    const estimate = memoryEstimate(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    try std.testing.expectEqual(@as(u64, 0), estimate);
}

test "storage allocates correct lengths" {
    var storage = try Storage.init(
        std.testing.allocator,
        .{ 2, 3, 4 },
        .{ 1, 2, 3 },
        std.math.maxInt(u64),
    );
    defer storage.deinit();

    try std.testing.expectEqual(@as(usize, 2), storage.regrets_flop.len);
    try std.testing.expectEqual(@as(usize, 2), storage.strategies_flop.len);
    try std.testing.expectEqual(@as(usize, 6), storage.regrets_turn.len);
    try std.testing.expectEqual(@as(usize, 6), storage.strategies_turn.len);
    try std.testing.expectEqual(@as(usize, 12), storage.regrets_river.len);
    try std.testing.expectEqual(@as(usize, 12), storage.strategies_river.len);
}

test "storage zero-initializes" {
    var storage = try Storage.init(
        std.testing.allocator,
        .{ 4, 0, 0 },
        .{ 1, 0, 0 },
        std.math.maxInt(u64),
    );
    defer storage.deinit();

    for (storage.regrets_flop) |v| {
        try std.testing.expectEqual(@as(f32, 0.0), v);
    }
    for (storage.strategies_flop) |v| {
        try std.testing.expectEqual(@as(f32, 0.0), v);
    }
}

test "storage budget exceeded" {
    const result = Storage.init(
        std.testing.allocator,
        .{ 1000, 1000, 1000 },
        .{ 1, 49, 2352 },
        100,
    );
    try std.testing.expectError(error.StorageBudgetExceeded, result);
}

test "storage budget just fits" {
    // 1 slot * 1 runout (flop only) = 1 slot * 8 bytes = 8 bytes
    var storage = try Storage.init(
        std.testing.allocator,
        .{ 1, 0, 0 },
        .{ 1, 0, 0 },
        8, // budget = 8, estimate = 8
    );
    defer storage.deinit();
    try std.testing.expectEqual(@as(usize, 1), storage.regrets_flop.len);
}

test "storage empty streets allocate zero-length slices" {
    var storage = try Storage.init(
        std.testing.allocator,
        .{ 0, 0, 0 },
        .{ 1, 1, 1 },
        std.math.maxInt(u64),
    );
    defer storage.deinit();

    try std.testing.expectEqual(@as(usize, 0), storage.regrets_flop.len);
    try std.testing.expectEqual(@as(usize, 0), storage.strategies_river.len);
}

test "slot address formula" {
    const addr = slotAddress(100, 5, 20, 2, 50, 3);
    try std.testing.expectEqual(@as(u64, 623), addr);
}

test "slot address first slot" {
    const addr = slotAddress(100, 0, 0, 0, 50, 0);
    try std.testing.expectEqual(@as(u64, 0), addr);
}

test "slot address last in runout block" {
    const addr = slotAddress(100, 1, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(u64, 100), addr);
}

test "slot address action-major stride" {
    const addr0 = slotAddress(100, 0, 10, 0, 50, 0);
    const addr1 = slotAddress(100, 0, 10, 1, 50, 0);
    try std.testing.expectEqual(@as(u64, 50), addr1 - addr0);
}

test "street slot address uses correct slots_per_runout" {
    const spa = [_]u64{ 10, 20, 30 };

    const flop = streetSlotAddress(spa, .flop, 2, 5, 0, 3, 1);
    try std.testing.expectEqual(slotAddress(10, 2, 5, 0, 3, 1), flop);

    const turn = streetSlotAddress(spa, .turn, 2, 5, 0, 3, 1);
    try std.testing.expectEqual(slotAddress(20, 2, 5, 0, 3, 1), turn);

    const river = streetSlotAddress(spa, .river, 2, 5, 0, 3, 1);
    try std.testing.expectEqual(slotAddress(30, 2, 5, 0, 3, 1), river);
}

test "write through slot address" {
    var storage = try Storage.init(
        std.testing.allocator,
        .{ 10, 0, 0 },
        .{ 3, 0, 0 },
        std.math.maxInt(u64),
    );
    defer storage.deinit();

    const addr = slotAddress(10, 2, 0, 0, 3, 1);
    try std.testing.expectEqual(@as(u64, 21), addr);

    storage.regrets_flop[@intCast(addr)] = 42.5;
    try std.testing.expectEqual(@as(f32, 42.5), storage.regrets_flop[@intCast(addr)]);
}

test "regret and strategy arrays independent" {
    var storage = try Storage.init(
        std.testing.allocator,
        .{ 1, 0, 0 },
        .{ 1, 0, 0 },
        std.math.maxInt(u64),
    );
    defer storage.deinit();

    storage.regrets_flop[0] = 3.0;
    storage.strategies_flop[0] = 7.0;

    try std.testing.expectEqual(@as(f32, 3.0), storage.regrets_flop[0]);
    try std.testing.expectEqual(@as(f32, 7.0), storage.strategies_flop[0]);
}
