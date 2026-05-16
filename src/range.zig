const std = @import("std");
const Allocator = std.mem.Allocator;
const card_mod = @import("card.zig");
const Card = card_mod.Card;

/// A Hand represents a pair of hole cards.
/// In the solver, we often refer to these by their index (0-1325).
pub const Hand = struct {
    card1: Card,
    card2: Card,

    pub fn init(c1: Card, c2: Card) Hand {
        // Standardize order: highest rank first, or highest suit if ranks equal.
        // This ensures {As, Ks} and {Ks, As} map to the same Hand.
        if (c1 > c2) {
            return .{ .card1 = c1, .card2 = c2 };
        } else {
            return .{ .card1 = c2, .card2 = c1 };
        }
    }

    pub fn format(
        self: Hand,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        const s1 = card_mod.get_card_str(self.card1) catch [2]u8{ '?', '?' };
        const s2 = card_mod.get_card_str(self.card2) catch [2]u8{ '?', '?' };
        try writer.print("{s}{s}", .{ s1, s2 });
    }
};

/// The HandTable stores all 1,326 possible unique hole card combinations.
/// This allows us to map any Hand to a u16 index for fast array lookups.
pub const HandTable = struct {
    all_hands: [1326]Hand,

    pub fn init() HandTable {
        var table: [1326]Hand = undefined;
        const deck = card_mod.makeDeck();
        var count: usize = 0;
        
        var i: usize = 0;
        while (i < 52) : (i += 1) {
            var j: usize = i + 1;
            while (j < 52) : (j += 1) {
                table[count] = Hand.init(deck[i], deck[j]);
                count += 1;
            }
        }
        return .{ .all_hands = table };
    }

    pub fn getIndex(self: *const HandTable, hand: Hand) ?u16 {
        // In a real solver, you'd use a perfect hash or a lookup table
        // to avoid this linear search. For now, this is simple and correct.
        for (self.all_hands, 0..) |h, i| {
            if (h.card1 == hand.card1 and h.card2 == hand.card2) {
                return @intCast(i);
            }
        }
        return null;
    }
    
    pub fn getHand(self: *const HandTable, index: u16) Hand {
        return self.all_hands[index];
    }
};

/// A Range represents a player's distribution of possible hands.
/// It uses 'active_indices' to prune hands with 0% probability,
/// making the CFR loops much faster.
pub const Range = struct {
    // The u16 indices (0-1325) of hands in this range
    active_indices: []u16,
    // The probability (0.0 to 1.0) of holding the hand at the same index in active_indices
    probs: []f32,
    
    pub fn initEmpty(allocator: Allocator, num_hands: usize) !Range {
        return .{
            .active_indices = try allocator.alloc(u16, num_hands),
            .probs = try allocator.alloc(f32, num_hands),
        };
    }

    pub fn deinit(self: *Range, allocator: Allocator) void {
        allocator.free(self.active_indices);
        allocator.free(self.probs);
    }
    
    /// Helper to normalize probabilities so they sum to 1.0 (optional)
    pub fn normalize(self: *Range) void {
        var sum: f32 = 0;
        for (self.probs) |p| sum += p;
        if (sum > 0) {
            for (self.probs) |*p| p.* /= sum;
        }
    }
};

test "HandTable: contains 1326 unique hands" {
    const table = HandTable.init();
    try std.testing.expectEqual(@as(usize, 1326), table.all_hands.len);
    
    // Spot check: AsKs
    const deck = card_mod.makeDeck();
    // makeDeck generates in rank order: 2, 3, ... A
    // Suits: S, H, D, C
    // Ace of Spades is likely at index 48 (12*4 + 0)
    // King of Spades is likely at index 44 (11*4 + 0)
    const as = deck[48];
    const ks = deck[44];
    const asks = Hand.init(as, ks);
    
    const idx = table.getIndex(asks);
    try std.testing.expect(idx != null);
    
    const retrieved = table.getHand(idx.?);
    try std.testing.expectEqual(asks.card1, retrieved.card1);
    try std.testing.expectEqual(asks.card2, retrieved.card2);
}
