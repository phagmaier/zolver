const std = @import("std");
const card = @import("card.zig");

const Allocator = std.mem.Allocator;
const Combo = card.Combo;

pub const WeightedCombo = @import("isomorphism.zig").WeightedCombo;

const max_combo_key: u16 = 50 * 52 + 51;

pub const Range = struct {
    allocator: Allocator,
    /// Hands in canonical combo order (sorted by first card index, then second).
    hands: []Combo,
    /// Weights aligned with hands, each in [0, 1].
    weights: []f32,

    /// Number of combos in this range.
    pub fn N(self: Range) u32 {
        return @intCast(self.hands.len);
    }

    pub fn deinit(self: *Range) void {
        self.allocator.free(self.hands);
        self.allocator.free(self.weights);
        self.* = undefined;
    }
};

/// Build a range-local hand index from user-provided weighted combos.
///
/// Filters out zero-weight entries and sorts in canonical combo order:
/// first by first-card index (0..50), then by second-card index (first+1..51).
pub fn buildRange(allocator: Allocator, input: []const WeightedCombo) !Range {
    var lookup = [_]?f32{null} ** (max_combo_key + 1);

    for (input) |entry| {
        if (entry.weight <= 0.0) continue;
        const key = entry.combo.canonicalKey();
        lookup[key] = entry.weight;
    }

    var count: u32 = 0;
    for (lookup) |maybe| {
        if (maybe != null) count += 1;
    }

    const hands = try allocator.alloc(Combo, count);
    errdefer allocator.free(hands);
    const weights = try allocator.alloc(f32, count);
    errdefer allocator.free(weights);

    var idx: u32 = 0;
    var first_idx: u8 = 0;
    while (first_idx < 52) : (first_idx += 1) {
        var second_idx: u8 = first_idx + 1;
        while (second_idx < 52) : (second_idx += 1) {
            const key = @as(u16, first_idx) * 52 + second_idx;
            if (lookup[key]) |weight| {
                hands[idx] = try Combo.init(
                    try card.fromIndex(first_idx),
                    try card.fromIndex(second_idx),
                );
                weights[idx] = weight;
                idx += 1;
            }
        }
    }

    return .{
        .allocator = allocator,
        .hands = hands,
        .weights = weights,
    };
}

test "empty input produces empty range" {
    var range = try buildRange(std.testing.allocator, &.{});
    defer range.deinit();
    try std.testing.expectEqual(@as(u32, 0), range.N());
}

test "single combo in range" {
    const ace_king = try Combo.init(card.makeCard(12, 0), card.makeCard(11, 0));
    const input = [_]WeightedCombo{.{ .combo = ace_king, .weight = 1.0 }};
    var range = try buildRange(std.testing.allocator, &input);
    defer range.deinit();

    try std.testing.expectEqual(@as(u32, 1), range.N());
    try std.testing.expect(range.hands[0].eql(ace_king));
    try std.testing.expectEqual(@as(f32, 1.0), range.weights[0]);
}

test "canonical ordering regardless of input order" {
    const later = try Combo.init(card.makeCard(12, 0), card.makeCard(11, 0)); // AK
    const earlier = try Combo.init(card.makeCard(1, 0), card.makeCard(0, 0)); // 32
    const input = [_]WeightedCombo{
        .{ .combo = later, .weight = 1.0 },
        .{ .combo = earlier, .weight = 0.5 },
    };
    var range = try buildRange(std.testing.allocator, &input);
    defer range.deinit();

    try std.testing.expectEqual(@as(u32, 2), range.N());
    try std.testing.expect(range.hands[0].eql(earlier));
    try std.testing.expect(range.hands[1].eql(later));
}

test "zero weight combos are filtered" {
    const combo = try Combo.init(card.makeCard(12, 0), card.makeCard(11, 0));
    const input = [_]WeightedCombo{.{ .combo = combo, .weight = 0.0 }};
    var range = try buildRange(std.testing.allocator, &input);
    defer range.deinit();

    try std.testing.expectEqual(@as(u32, 0), range.N());
}

test "negative weight combos are filtered" {
    const combo = try Combo.init(card.makeCard(12, 0), card.makeCard(11, 0));
    const input = [_]WeightedCombo{.{ .combo = combo, .weight = -0.5 }};
    var range = try buildRange(std.testing.allocator, &input);
    defer range.deinit();

    try std.testing.expectEqual(@as(u32, 0), range.N());
}

test "mixed zero and nonzero weights" {
    const a = try Combo.init(card.makeCard(12, 0), card.makeCard(11, 0));
    const b = try Combo.init(card.makeCard(0, 0), card.makeCard(1, 0));
    const input = [_]WeightedCombo{
        .{ .combo = a, .weight = 0.0 },
        .{ .combo = b, .weight = 1.0 },
    };
    var range = try buildRange(std.testing.allocator, &input);
    defer range.deinit();

    try std.testing.expectEqual(@as(u32, 1), range.N());
    try std.testing.expect(range.hands[0].eql(b));
}

test "duplicate combo uses last nonzero weight" {
    const combo = try Combo.init(card.makeCard(12, 0), card.makeCard(11, 0));
    const input = [_]WeightedCombo{
        .{ .combo = combo, .weight = 0.7 },
        .{ .combo = combo, .weight = 1.0 },
    };
    var range = try buildRange(std.testing.allocator, &input);
    defer range.deinit();

    try std.testing.expectEqual(@as(u32, 1), range.N());
    try std.testing.expectEqual(@as(f32, 1.0), range.weights[0]);
}

test "all combos enumerated in canonical order" {
    // Build a range containing the first 3 combos in canonical order:
    // (0,1)=0*52+1=1, (0,2)=0*52+2=2, (0,3)=0*52+3=3
    const c01 = try Combo.init(try card.fromIndex(0), try card.fromIndex(1));
    const c02 = try Combo.init(try card.fromIndex(0), try card.fromIndex(2));
    const c03 = try Combo.init(try card.fromIndex(0), try card.fromIndex(3));
    const input = [_]WeightedCombo{
        .{ .combo = c03, .weight = 0.3 },
        .{ .combo = c01, .weight = 0.1 },
        .{ .combo = c02, .weight = 0.2 },
    };
    var range = try buildRange(std.testing.allocator, &input);
    defer range.deinit();

    try std.testing.expectEqual(@as(u32, 3), range.N());
    try std.testing.expect(range.hands[0].eql(c01));
    try std.testing.expect(range.hands[1].eql(c02));
    try std.testing.expect(range.hands[2].eql(c03));
    try std.testing.expectEqual(@as(f32, 0.1), range.weights[0]);
    try std.testing.expectEqual(@as(f32, 0.2), range.weights[1]);
    try std.testing.expectEqual(@as(f32, 0.3), range.weights[2]);
}

test "full range N matches input count" {
    // 10 random combos should produce N=10
    const count: u32 = 10;
    var input: [10]WeightedCombo = undefined;
    for (0..count) |i| {
        const first_idx: u8 = @intCast(i);
        const second_idx: u8 = @intCast(i + 1);
        input[i] = .{
            .combo = try Combo.init(try card.fromIndex(first_idx), try card.fromIndex(second_idx)),
            .weight = 1.0,
        };
    }
    var range = try buildRange(std.testing.allocator, &input);
    defer range.deinit();

    try std.testing.expectEqual(count, range.N());
    // Verify weights are all 1.0 and hands are unique
    for (range.hands, 0..) |hand, j| {
        try std.testing.expectEqual(@as(f32, 1.0), range.weights[j]);
        for (range.hands[j + 1 ..]) |other| {
            try std.testing.expect(!hand.eql(other));
        }
    }
}
