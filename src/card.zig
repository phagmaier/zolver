const std = @import("std");

pub const Card = u32;

pub const rank_count: u8 = 13;
pub const suit_count: u8 = 4;
pub const deck_count: u8 = 52;

pub const SPADE: u32 = 0b0001;
pub const HEART: u32 = 0b0010;
pub const DIAMOND: u32 = 0b0100;
pub const CLUB: u32 = 0b1000;

pub fn makeCard(rank: u32, suit: u32) Card {
    const rank_bits = rank << 8;
    const suit_bits = (@as(u32, 1) << @intCast(suit)) << 12;
    return rank_bits | suit_bits;
}

pub fn tryMakeCard(rank: u8, suit: u8) !Card {
    if (rank >= rank_count) return error.InvalidRank;
    if (suit >= suit_count) return error.InvalidSuit;
    return makeCard(rank, suit);
}

pub fn rankIndex(card: Card) u8 {
    return @intCast((card >> 8) & 0xF);
}

pub fn suitMask(card: Card) u32 {
    return (card >> 12) & 0xF;
}

pub fn suitIndex(card: Card) u8 {
    return @intCast(@ctz(suitMask(card)));
}

pub fn index(card: Card) u8 {
    return rankIndex(card) * suit_count + suitIndex(card);
}

pub fn fromIndex(card_index: u8) !Card {
    if (card_index >= deck_count) return error.InvalidCardIndex;
    return makeCard(card_index / suit_count, card_index % suit_count);
}

pub fn mask(card: Card) u64 {
    return @as(u64, 1) << @intCast(index(card));
}

pub fn applySuitMap(card: Card, suit_map: [4]u8) Card {
    return makeCard(rankIndex(card), suit_map[suitIndex(card)]);
}

/// Compute the combined u64 bitmask of multiple cards.
pub fn boardMask(cards: []const Card) u64 {
    var m: u64 = 0;
    for (cards) |c| m |= mask(c);
    return m;
}

const rank_char_lookup = [13]u8{ '2', '3', '4', '5', '6', '7', '8', '9', 'T', 'J', 'Q', 'K', 'A' };

/// Lowercase suit characters indexed by `suitIndex` (0=s, 1=h, 2=d, 3=c),
/// matching the input notation used by the parser ("As Kd 7h").
pub const suit_char_lower = [4]u8{ 's', 'h', 'd', 'c' };

/// Two-character lowercase-suit label for a card, e.g. "As", "7h", "2c".
pub fn cardStr(c: Card) [2]u8 {
    return .{ rank_char_lookup[rankIndex(c)], suit_char_lower[suitIndex(c)] };
}

pub const Combo = struct {
    first: Card,
    second: Card,

    pub fn init(a: Card, b: Card) !Combo {
        if (index(a) == index(b)) return error.DuplicateCard;
        if (index(a) < index(b)) {
            return .{ .first = a, .second = b };
        }
        return .{ .first = b, .second = a };
    }

    pub fn cardMask(self: Combo) u64 {
        return mask(self.first) | mask(self.second);
    }

    pub fn conflictsWithMask(self: Combo, dead_cards: u64) bool {
        return (self.cardMask() & dead_cards) != 0;
    }

    pub fn eql(self: Combo, other: Combo) bool {
        return index(self.first) == index(other.first) and index(self.second) == index(other.second);
    }

    pub fn applySuitMap(self: Combo, suit_map: [4]u8) !Combo {
        return Combo.init(
            makeCard(rankIndex(self.first), suit_map[suitIndex(self.first)]),
            makeCard(rankIndex(self.second), suit_map[suitIndex(self.second)]),
        );
    }

    /// Deterministic sort key: first * 52 + second (0..2651).
    pub fn canonicalKey(self: Combo) u16 {
        return @as(u16, index(self.first)) * 52 + index(self.second);
    }
};

pub fn makeDeck() [52]Card {
    var deck: [52]Card = undefined;
    var idx: usize = 0;
    var rank: u32 = 0;
    while (rank < 13) : (rank += 1) {
        var suit: u32 = 0;
        while (suit < 4) : (suit += 1) {
            deck[idx] = makeCard(rank, suit);
            idx += 1;
        }
    }
    return deck;
}

pub fn print_card(card: u32) !void {
    const r = rankIndex(card);
    if (r >= rank_char_lookup.len) return error.InvalidCard;
    const rank = rank_char_lookup[r];

    const suit_bits = suitMask(card);
    const suit: u8 = switch (suit_bits) {
        SPADE => 'S',
        HEART => 'H',
        DIAMOND => 'D',
        CLUB => 'C',
        else => return error.InvalidCard,
    };

    std.debug.print("{c}{c}\n", .{ rank, suit });
}

pub fn get_card_str(card: u32) ![2]u8 {
    const r = rankIndex(card);
    if (r >= rank_char_lookup.len) return error.InvalidCard;
    const suit_bits = suitMask(card);
    const suit: u8 = switch (suit_bits) {
        SPADE => 'S',
        HEART => 'H',
        DIAMOND => 'D',
        CLUB => 'C',
        else => return error.InvalidCard,
    };
    return .{ rank_char_lookup[r], suit };
}

test "card index round trip and suit map" {
    var i: u8 = 0;
    while (i < deck_count) : (i += 1) {
        const c = try fromIndex(i);
        try std.testing.expectEqual(i, index(c));
    }

    const ace_spades = makeCard(12, 0);
    const swapped = applySuitMap(ace_spades, .{ 1, 0, 2, 3 });
    try std.testing.expectEqual(@as(u8, 12), rankIndex(swapped));
    try std.testing.expectEqual(@as(u8, 1), suitIndex(swapped));
}

test "combo canonicalizes and detects conflicts" {
    const a = makeCard(12, 3);
    const b = makeCard(0, 0);
    const combo = try Combo.init(a, b);
    try std.testing.expectEqual(index(b), index(combo.first));
    try std.testing.expectEqual(index(a), index(combo.second));
    try std.testing.expect(combo.conflictsWithMask(mask(a)));
    try std.testing.expect(!combo.conflictsWithMask(mask(makeCard(7, 2))));
}
