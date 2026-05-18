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

fn deckIndex(card: Card) ?u16 {
    const rank: u16 = @intCast((card >> 8) & 0xF);
    if (rank >= 13) return null;
    const suit_bits: u32 = (card >> 12) & 0xF;
    if (suit_bits == 0 or (suit_bits & (suit_bits - 1)) != 0) return null;
    const suit_idx: u16 = @intCast(@ctz(suit_bits));
    return rank * 4 + suit_idx;
}

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
        _ = self;
        // Deck index = rank*4 + suit_index. Cards encode rank in bits 8..11
        // and suit one-hot in bits 12..15 (SPADE..CLUB), so @ctz of the suit
        // nibble recovers suit_index in 0..3. See card.makeDeck for the
        // ordering this mirrors.
        const a = deckIndex(hand.card1) orelse return null;
        const b = deckIndex(hand.card2) orelse return null;
        if (a == b) return null;
        const lo: u16 = if (a < b) a else b;
        const hi: u16 = if (a < b) b else a;
        // Combinatorial unrank for unordered pairs over 52 elements with lo<hi:
        // matches the (i, j>i) traversal in HandTable.init.
        return lo * (103 - lo) / 2 + (hi - lo - 1);
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

test "HandTable.getIndex: O(1) lookup round-trips every hand" {
    const table = HandTable.init();
    // For every stored slot, getIndex(getHand(slot)) must return slot, and
    // the lookup must be order-independent in the input pair.
    var slot: u16 = 0;
    while (slot < 1326) : (slot += 1) {
        const h = table.getHand(slot);
        try std.testing.expectEqual(slot, table.getIndex(h).?);
        const swapped = Hand.init(h.card2, h.card1);
        try std.testing.expectEqual(slot, table.getIndex(swapped).?);
    }
}

test "HandTable.getIndex: duplicate cards return null" {
    const table = HandTable.init();
    const as = card_mod.makeCard(12, 0);
    // Hand.init normally enforces distinct cards via Card> ordering, but the
    // lookup itself must defend against a same-card pair reaching getIndex.
    const dup: Hand = .{ .card1 = as, .card2 = as };
    try std.testing.expect(table.getIndex(dup) == null);
}
